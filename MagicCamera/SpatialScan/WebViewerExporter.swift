//
//  WebViewerExporter.swift
//  Magic Camera
//
//  Exports a scan as a single self-contained HTML file: a three.js viewer with
//  the model embedded as base64 (point cloud → raw position/colour arrays,
//  mesh → GLB, optionally textured). The three.js runtime (r147 UMD +
//  OrbitControls + GLTFLoader) is bundled with the app and inlined into the
//  file, so the result works fully offline; if the bundled runtime is missing
//  (e.g. unit-test hosts) it falls back to the same files from a pinned CDN.
//

import Foundation
import simd

enum WebViewerExporter {
    /// Caps the embedded cloud so the HTML stays a sane size (~12 MB base64).
    static let maxEmbeddedPoints = 600_000

    // MARK: - Entry points

    static func write(cloud: PointCloud,
                      filename: String = "MagicCamera-viewer") throws -> URL {
        let capped = cloud.downsampled(maxCount: maxEmbeddedPoints)

        var positionData = Data(capacity: capped.count * 12)
        var colorData = Data(capacity: capped.count * 3)
        for i in 0..<capped.count {
            appendFloat(capped.positions[i].x, to: &positionData)
            appendFloat(capped.positions[i].y, to: &positionData)
            appendFloat(capped.positions[i].z, to: &positionData)
            colorData.append(UInt8(min(max(capped.colors[i].x, 0), 1) * 255))
            colorData.append(UInt8(min(max(capped.colors[i].y, 0), 1) * 255))
            colorData.append(UInt8(min(max(capped.colors[i].z, 0), 1) * 255))
        }

        let html = pointsHTML(positionsBase64: positionData.base64EncodedString(),
                              colorsBase64: colorData.base64EncodedString(),
                              pointCount: capped.count)
        return try writeHTML(html, filename: filename)
    }

    static func write(mesh: MeshData,
                      filename: String = "MagicCamera-viewer") throws -> URL {
        let glb = try MeshGLBExporter.data(from: mesh)
        return try writeHTML(glbHTML(glbBase64: glb.base64EncodedString()), filename: filename)
    }

    static func write(textured: TexturedMesh,
                      filename: String = "MagicCamera-viewer") throws -> URL {
        let glb = try TexturedMeshExporter.glbData(from: textured)
        return try writeHTML(glbHTML(glbBase64: glb.base64EncodedString()), filename: filename)
    }

    private static func writeHTML(_ html: String, filename: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(filename).html")
        try? FileManager.default.removeItem(at: url)
        try html.data(using: .utf8)!.write(to: url, options: .atomic)
        return url
    }

    // MARK: - three.js runtime (bundled, CDN fallback)

    /// Inlined bundled runtime, or pinned-CDN script tags when the resource is
    /// unavailable. The viewer code only uses the THREE global either way.
    static func runtimeScriptTags() -> String {
        if let url = Bundle.main.url(forResource: "WebViewerRuntime", withExtension: "js"),
           let runtime = try? String(contentsOf: url, encoding: .utf8) {
            return "<script>\n\(runtime)\n</script>"
        }
        return """
        <script src="https://unpkg.com/three@0.147.0/build/three.min.js"></script>
        <script src="https://unpkg.com/three@0.147.0/examples/js/controls/OrbitControls.js"></script>
        <script src="https://unpkg.com/three@0.147.0/examples/js/loaders/GLTFLoader.js"></script>
        """
    }

    // MARK: - Templates

    private static func headCommon() -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Magic Camera Scan</title>
        <style>
          html, body { margin: 0; height: 100%; background: #0b0d10; overflow: hidden; }
          #hud { position: fixed; left: 12px; bottom: 12px; color: #9aa3ad;
                 font: 12px -apple-system, system-ui, sans-serif; user-select: none; }
          canvas { display: block; }
          #modeBar { position: fixed; top: 12px; right: 12px; display: flex; gap: 8px; }
          .btn { padding: 8px 14px; border-radius: 999px; border: 1px solid #2a3340;
                 background: #161b22cc; color: #dbe2ea; cursor: pointer;
                 font: 13px -apple-system, system-ui, sans-serif; }
          .btn.active { background: #39c2ff; color: #000; border-color: #39c2ff; }
          #speedWrap { position: fixed; top: 56px; right: 12px; display: none;
                       color: #9aa3ad; background: #161b22cc; padding: 8px 12px;
                       border-radius: 12px; font: 12px -apple-system, system-ui, sans-serif; }
          #stick { position: fixed; left: 18px; bottom: 90px; width: 110px; height: 110px;
                   border-radius: 50%; background: #ffffff14; border: 1px solid #ffffff22;
                   display: none; touch-action: none; }
          #knob { position: absolute; left: 32px; top: 32px; width: 46px; height: 46px;
                  border-radius: 50%; background: #39c2ffd0; }
        </style>
        </head>
        <body>
        <div id="hud"></div>
        <div id="modeBar">
          <button id="modeOrbit" class="btn active">Orbit</button>
          <button id="modeWalk" class="btn">Walk</button>
        </div>
        <div id="speedWrap">Speed <input id="speed" type="range" min="0.3" max="3.5" step="0.1" value="1.2"></div>
        <div id="stick"><div id="knob"></div></div>
        \(runtimeScriptTags())
        """
    }

    private static let sceneCommon = """
    const renderer = new THREE.WebGLRenderer({ antialias: true });
    renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
    renderer.setSize(innerWidth, innerHeight);
    renderer.outputEncoding = THREE.sRGBEncoding;
    document.body.appendChild(renderer.domElement);

    const scene = new THREE.Scene();
    scene.background = new THREE.Color(0x0b0d10);
    const camera = new THREE.PerspectiveCamera(55, innerWidth / innerHeight, 0.01, 200);
    const controls = new THREE.OrbitControls(camera, renderer.domElement);
    controls.enableDamping = true;

    function decode(b64) {
      const s = atob(b64), bytes = new Uint8Array(s.length);
      for (let i = 0; i < s.length; i++) bytes[i] = s.charCodeAt(i);
      return bytes;
    }

    let modelSize = 1;
    let modelBox = null;
    function frame(object) {
      const box = new THREE.Box3().setFromObject(object);
      const center = box.getCenter(new THREE.Vector3());
      modelSize = box.getSize(new THREE.Vector3()).length() || 1;
      object.position.sub(center);
      modelBox = new THREE.Box3().setFromObject(object);
      camera.position.set(modelSize * 0.7, modelSize * 0.5, modelSize * 0.9);
      camera.near = modelSize / 500; camera.far = modelSize * 20;
      camera.updateProjectionMatrix();
      controls.target.set(0, 0, 0);
    }

    // --- First-person walk mode: WASD/arrows or the on-screen joystick to
    // move on the floor plane, drag to look around, slider sets the speed. ---
    let mode = 'orbit';
    let baseHud = '';
    function hud(text) { document.getElementById('hud').textContent = text; }
    let yaw = 0, pitch = 0;
    const keys = {};
    let stickVec = { x: 0, y: 0 };
    let walkSpeed = 1.2;
    const clock = new THREE.Clock();
    camera.rotation.order = 'YXZ';

    function setMode(next) {
      mode = next;
      controls.enabled = (next === 'orbit');
      document.getElementById('modeOrbit').classList.toggle('active', next === 'orbit');
      document.getElementById('modeWalk').classList.toggle('active', next === 'walk');
      document.getElementById('speedWrap').style.display = next === 'walk' ? 'block' : 'none';
      document.getElementById('stick').style.display = next === 'walk' ? 'block' : 'none';
      if (next === 'walk') {
        if (modelBox) {
          const eyeY = Math.min(modelBox.min.y + 1.55, modelBox.max.y - 0.05);
          camera.position.set(0, eyeY, 0);
        }
        yaw = 0; pitch = 0;
        camera.rotation.set(0, 0, 0);
        hud('Walk: drag to look, WASD/joystick to move · double-tap twice to measure');
      } else {
        controls.target.set(0, 0, 0);
        hud(baseHud);
      }
    }
    document.getElementById('modeOrbit').onclick = () => setMode('orbit');
    document.getElementById('modeWalk').onclick = () => setMode('walk');
    document.getElementById('speed').addEventListener('input',
      (e) => { walkSpeed = Number(e.target.value); });

    addEventListener('keydown', (e) => { keys[e.code] = 1; });
    addEventListener('keyup', (e) => { keys[e.code] = 0; });

    let looking = false, lastX = 0, lastY = 0;
    renderer.domElement.addEventListener('pointerdown', (e) => {
      if (mode !== 'walk') return;
      looking = true; lastX = e.clientX; lastY = e.clientY;
    });
    addEventListener('pointermove', (e) => {
      if (!looking || mode !== 'walk') return;
      yaw -= (e.clientX - lastX) * 0.0032;
      pitch -= (e.clientY - lastY) * 0.0032;
      pitch = Math.max(-1.35, Math.min(1.35, pitch));
      lastX = e.clientX; lastY = e.clientY;
      camera.rotation.set(pitch, yaw, 0);
    });
    addEventListener('pointerup', () => { looking = false; });

    const stick = document.getElementById('stick');
    const knob = document.getElementById('knob');
    let stickId = null;
    function moveKnob(e) {
      const r = stick.getBoundingClientRect();
      let dx = e.clientX - (r.left + r.width / 2);
      let dy = e.clientY - (r.top + r.height / 2);
      const m = Math.hypot(dx, dy), max = 44;
      if (m > max) { dx *= max / m; dy *= max / m; }
      knob.style.left = (32 + dx) + 'px'; knob.style.top = (32 + dy) + 'px';
      stickVec = { x: dx / max, y: -dy / max };
    }
    function endStick(e) {
      if (e.pointerId !== stickId) return;
      stickId = null; stickVec = { x: 0, y: 0 };
      knob.style.left = '32px'; knob.style.top = '32px';
    }
    stick.addEventListener('pointerdown', (e) => {
      stickId = e.pointerId; stick.setPointerCapture(stickId); moveKnob(e);
    });
    stick.addEventListener('pointermove', (e) => {
      if (e.pointerId === stickId) moveKnob(e);
    });
    stick.addEventListener('pointerup', endStick);
    stick.addEventListener('pointercancel', endStick);

    function walkStep(dt) {
      let f = (keys['KeyW'] || keys['ArrowUp'] || 0) - (keys['KeyS'] || keys['ArrowDown'] || 0) + stickVec.y;
      let r = (keys['KeyD'] || keys['ArrowRight'] || 0) - (keys['KeyA'] || keys['ArrowLeft'] || 0) + stickVec.x;
      f = Math.max(-1, Math.min(1, f)); r = Math.max(-1, Math.min(1, r));
      if (!f && !r) return;
      const fwd = new THREE.Vector3();
      camera.getWorldDirection(fwd);
      fwd.y = 0;
      if (fwd.lengthSq() < 1e-6) return;
      fwd.normalize();
      const right = new THREE.Vector3().crossVectors(fwd, new THREE.Vector3(0, 1, 0));
      camera.position.addScaledVector(fwd, f * walkSpeed * dt);
      camera.position.addScaledVector(right, r * walkSpeed * dt);
    }

    function tick() {
      const dt = Math.min(clock.getDelta(), 0.05);
      if (mode === 'walk') walkStep(dt); else controls.update();
    }

    // Measurement: double-tap places two markers on the model, HUD shows the
    // real-world distance (the scan is metric).
    const pickables = [];
    const measureGroup = new THREE.Group();
    scene.add(measureGroup);
    const raycaster = new THREE.Raycaster();
    let measurePoints = [];
    function formatDistance(d) {
      return d >= 1 ? d.toFixed(2) + ' m' : (d * 100).toFixed(1) + ' cm';
    }
    renderer.domElement.addEventListener('dblclick', (event) => {
      const rect = renderer.domElement.getBoundingClientRect();
      const ndc = new THREE.Vector2(
        ((event.clientX - rect.left) / rect.width) * 2 - 1,
        -((event.clientY - rect.top) / rect.height) * 2 + 1);
      raycaster.setFromCamera(ndc, camera);
      raycaster.params.Points.threshold = modelSize * 0.01;
      const hits = raycaster.intersectObjects(pickables, true);
      if (!hits.length) return;
      if (measurePoints.length >= 2) { measurePoints = []; measureGroup.clear(); }
      const p = hits[0].point.clone();
      measurePoints.push(p);
      const marker = new THREE.Mesh(
        new THREE.SphereGeometry(modelSize * 0.008),
        new THREE.MeshBasicMaterial({ color: 0xffd60a }));
      marker.position.copy(p);
      measureGroup.add(marker);
      if (measurePoints.length === 2) {
        const geo = new THREE.BufferGeometry().setFromPoints(measurePoints);
        measureGroup.add(new THREE.Line(geo, new THREE.LineBasicMaterial({ color: 0xffd60a })));
        document.getElementById('hud').textContent =
          'Distance: ' + formatDistance(measurePoints[0].distanceTo(measurePoints[1]))
          + ' · double-tap to measure again';
      }
    });

    addEventListener('resize', () => {
      camera.aspect = innerWidth / innerHeight;
      camera.updateProjectionMatrix();
      renderer.setSize(innerWidth, innerHeight);
    });

    renderer.setAnimationLoop(() => { tick(); renderer.render(scene, camera); });
    """

    private static func pointsHTML(positionsBase64: String, colorsBase64: String,
                                   pointCount: Int) -> String {
        headCommon() + """
        <script>
        \(sceneCommon)

        const positions = new Float32Array(decode('\(positionsBase64)').buffer);
        const colors = decode('\(colorsBase64)');

        const geometry = new THREE.BufferGeometry();
        geometry.setAttribute('position', new THREE.BufferAttribute(positions, 3));
        geometry.setAttribute('color', new THREE.BufferAttribute(colors, 3, true));

        const material = new THREE.PointsMaterial({
          size: 0.006, vertexColors: true, sizeAttenuation: true });
        const points = new THREE.Points(geometry, material);
        scene.add(points);
        pickables.push(points);
        frame(points);

        // Eye-dome lighting: render to an offscreen target with a depth
        // texture, then a full-screen pass darkens pixels whose neighbours are
        // closer — silhouettes pop instead of the cloud looking flat.
        function makeTarget() {
          const ratio = Math.min(devicePixelRatio, 2);
          const w = Math.floor(innerWidth * ratio), h = Math.floor(innerHeight * ratio);
          const target = new THREE.WebGLRenderTarget(w, h, {
            minFilter: THREE.NearestFilter, magFilter: THREE.NearestFilter });
          target.depthTexture = new THREE.DepthTexture(w, h);
          return target;
        }
        let target = makeTarget();

        const edlMaterial = new THREE.ShaderMaterial({
          uniforms: {
            tColor: { value: null }, tDepth: { value: null },
            resolution: { value: new THREE.Vector2() },
            strength: { value: 40.0 },
            cameraNear: { value: 0.01 }, cameraFar: { value: 200.0 }
          },
          vertexShader: `varying vec2 vUv;
            void main() { vUv = uv; gl_Position = vec4(position.xy, 0.0, 1.0); }`,
          fragmentShader: `varying vec2 vUv;
            uniform sampler2D tColor; uniform sampler2D tDepth;
            uniform vec2 resolution; uniform float strength;
            uniform float cameraNear; uniform float cameraFar;
            float linearDepth(vec2 uv) {
              float ndc = texture2D(tDepth, uv).x * 2.0 - 1.0;
              return (2.0 * cameraNear * cameraFar)
                   / (cameraFar + cameraNear - ndc * (cameraFar - cameraNear));
            }
            void main() {
              vec4 color = texture2D(tColor, vUv);
              float d = linearDepth(vUv);
              if (d >= cameraFar * 0.99) { gl_FragColor = color; return; }
              vec2 px = 1.0 / resolution;
              float obscurance = 0.0;
              for (int i = 0; i < 8; i++) {
                float a = float(i) * 0.785398;
                vec2 offset = vec2(cos(a), sin(a)) * px * 1.5;
                obscurance += max(0.0, log2(d) - log2(linearDepth(vUv + offset)));
              }
              float shade = exp(-obscurance * strength / 8.0);
              gl_FragColor = vec4(color.rgb * shade, color.a);
            }`
        });
        const edlScene = new THREE.Scene();
        const edlCamera = new THREE.Camera();
        edlScene.add(new THREE.Mesh(new THREE.PlaneGeometry(2, 2), edlMaterial));

        addEventListener('resize', () => { target.dispose(); target = makeTarget(); });

        renderer.setAnimationLoop(() => {
          tick();
          renderer.setRenderTarget(target);
          renderer.render(scene, camera);
          renderer.setRenderTarget(null);
          edlMaterial.uniforms.tColor.value = target.texture;
          edlMaterial.uniforms.tDepth.value = target.depthTexture;
          edlMaterial.uniforms.resolution.value.set(target.width, target.height);
          edlMaterial.uniforms.cameraNear.value = camera.near;
          edlMaterial.uniforms.cameraFar.value = camera.far;
          renderer.render(edlScene, edlCamera);
        });

        baseHud = 'Magic Camera · \(pointCount) points · drag to orbit · double-tap twice to measure';
        hud(baseHud);
        </script>
        </body></html>
        """
    }

    private static func glbHTML(glbBase64: String) -> String {
        headCommon() + """
        <script>
        \(sceneCommon)

        scene.add(new THREE.HemisphereLight(0xffffff, 0x33414f, 1.1));
        const sun = new THREE.DirectionalLight(0xffffff, 1.4);
        sun.position.set(2, 4, 3);
        scene.add(sun);

        const glb = decode('\(glbBase64)');
        new THREE.GLTFLoader().parse(glb.buffer, '', (gltf) => {
          scene.add(gltf.scene);
          pickables.push(gltf.scene);
          frame(gltf.scene);
          baseHud = 'Magic Camera · drag to orbit · double-tap twice to measure';
          hud(baseHud);
        }, (error) => {
          document.getElementById('hud').textContent = 'Failed to load model: ' + error;
        });
        </script>
        </body></html>
        """
    }

    // MARK: - Helpers

    private static func appendFloat(_ value: Float, to data: inout Data) {
        var le = value.bitPattern.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
}
