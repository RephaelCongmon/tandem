#!/usr/bin/env swift
// Sends a debug command to a running Debug build: debug-command.swift <profile> <command> [argument]
import Foundation
let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: debug-command.swift <profile> <command> [argument]"); exit(1) }
let object = ([args[1], args[2]] + (args.count > 3 ? [args[3...].joined(separator: " ")] : [])).joined(separator: "|")
DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.rofel.tandem.debug"), object: object, userInfo: nil, deliverImmediately: true)
print("sent \(object)")
