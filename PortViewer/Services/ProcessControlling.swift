import Foundation

protocol ProcessControlling: Sendable {
    func send(signal: Int32, to pid: Int32) throws
    func exists(pid: Int32) -> Bool
}
