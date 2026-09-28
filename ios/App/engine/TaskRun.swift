import Foundation

/// One active task run; the service calls stop() to pause or cancel it.
protocol TaskRun: Actor {
    func stop() async
}
