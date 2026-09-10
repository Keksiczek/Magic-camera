//
//  OnboardingView.swift
//  Magic Camera
//
//  First-run flow. Three jobs, in the order they matter:
//
//  1. Say what the app is for, so the home screen's intent groups land.
//  2. Teach the one thing that decides whether a first scan is good or garbage —
//     sweep slowly and keep the subject framed. A bad first scan is the most
//     likely reason someone deletes a scanner app.
//  3. Prime the camera permission. Until now ARKit raised the system prompt cold,
//     the first time a capture mode opened; a denial there is effectively
//     unrecoverable in-app. Explaining first, then asking, is the difference
//     between an informed yes and a reflexive no — and it lets us say the privacy
//     part ("nothing leaves your device") at the moment it is being asked about.
//
//  Shown once, gated on `AppSettings.hasSeenOnboarding`, and replayable from
//  Settings ▸ About ▸ Welcome tour.
//

import AVFoundation
import SwiftUI

struct OnboardingView: View {
    /// Called when the flow finishes (or is skipped) — the caller persists the
    /// "seen" flag and dismisses.
    let onFinish: () -> Void

    @State private var page = 0
    @State private var isRequestingCamera = false

    private static let pageCount = 3

    var body: some View {
        VStack(spacing: 0) {
            skipBar

            TabView(selection: $page) {
                OnboardingPage(
                    symbol: "cube.transparent.fill",
                    gradient: [Theme.accent, Color(red: 0.34, green: 0.62, blue: 0.90)],
                    title: "Capture the world in 3D",
                    message: "Point your iPhone at a room or an object and Magic Camera turns what the LiDAR sensor sees into a real, textured 3D model you can measure, edit and share.",
                    bullets: [
                        ("house.fill", "Whole rooms, in one slow sweep"),
                        ("shippingbox.fill", "Single objects, down to the detail"),
                        ("square.and.arrow.up", "Export to USDZ, GLB, OBJ, STL or PLY")
                    ])
                    .tag(0)

                OnboardingPage(
                    symbol: "figure.walk.motion",
                    gradient: [Theme.accentWarm, Color(red: 0.95, green: 0.3, blue: 0.45)],
                    title: "Move slowly, cover everything",
                    message: "Scan quality is mostly technique. Three habits do almost all the work:",
                    bullets: [
                        ("tortoise.fill", "Sweep slowly — fast motion blurs depth"),
                        ("arrow.triangle.2.circlepath", "Circle the subject, look from above and below"),
                        ("lightbulb.fill", "Even, bright light; avoid mirrors and glass")
                    ])
                    .tag(1)

                OnboardingPage(
                    symbol: "lock.shield.fill",
                    gradient: [Color(red: 0.2, green: 0.65, blue: 0.55), Color(red: 0.1, green: 0.45, blue: 0.7)],
                    title: "Everything stays on your iPhone",
                    message: "Scanning happens entirely on-device — no account, no upload, no analytics. Your scans go to iCloud Drive only if you turn that on, and are shared only when you choose to share them.",
                    bullets: [
                        ("camera.fill", "The camera and LiDAR are used only while you scan"),
                        ("icloud.slash", "Nothing is sent anywhere by default")
                    ])
                    .tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            footer
        }
        .background(Theme.appBackgroundGradient.ignoresSafeArea())
        .interactiveDismissDisabled()
    }

    // MARK: - Chrome

    private var skipBar: some View {
        HStack {
            Spacer()
            Button("Skip") { onFinish() }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .accessibilityHint("Skips the welcome tour")
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Button(action: advance) {
                Text(isLastPage ? "Allow camera & start" : "Continue")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isRequestingCamera)

            // Stated up front so the permission sheet is never a surprise, and so
            // "Skip" is visibly not a dead end.
            Text(isLastPage
                 ? "iOS will ask for camera access next. You can also allow it later, the first time you open a capture mode."
                 : " ")
                .font(.caption2)
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .padding(.top, 8)
    }

    private var isLastPage: Bool { page == Self.pageCount - 1 }

    private func advance() {
        guard isLastPage else {
            withAnimation { page += 1 }
            return
        }
        requestCameraThenFinish()
    }

    /// Raises the system camera prompt from a screen that has just explained why,
    /// then finishes regardless of the answer — a denial is the user's call, and
    /// the capture modes already have their own unsupported/denied states.
    private func requestCameraThenFinish() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined else {
            onFinish()
            return
        }
        isRequestingCamera = true
        AVCaptureDevice.requestAccess(for: .video) { _ in
            Task { @MainActor in
                isRequestingCamera = false
                onFinish()
            }
        }
    }
}

/// One page: a gradient glyph, a headline, a paragraph and a few concrete
/// bullets. Scrollable because at accessibility text sizes the copy alone can
/// exceed the screen.
private struct OnboardingPage: View {
    let symbol: String
    let gradient: [Color]
    let title: String
    let message: String
    let bullets: [(String, String)]

    @ScaledMetric(relativeTo: .largeTitle) private var mark: CGFloat = 96

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.cornerXL, style: .continuous)
                        .fill(LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: mark, height: mark)
                        .shadow(color: gradient[0].opacity(0.45), radius: 22, y: 10)
                    Image(systemName: symbol)
                        .font(.system(size: mark * 0.42, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 16)
                .accessibilityHidden(true)

                Text(title)
                    .font(.system(.title, design: .rounded, weight: .heavy))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(bullets, id: \.1) { bullet in
                        Label {
                            Text(bullet.1)
                                .font(.subheadline)
                                .foregroundStyle(Theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: bullet.0)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(gradient[0])
                        }
                    }
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }
}
