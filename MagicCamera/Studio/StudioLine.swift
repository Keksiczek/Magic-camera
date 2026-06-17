//
//  StudioLine.swift
//  Magic Camera
//
//  One line of the Model Studio chat transcript. `tool` lines are the factual
//  results of individual tool calls — shown as activity rows between the chat
//  bubbles.
//

import Foundation

struct StudioLine: Identifiable, Equatable {
    enum Role: Equatable { case user, assistant, tool }
    let id = UUID()
    var role: Role
    var text: String
}
