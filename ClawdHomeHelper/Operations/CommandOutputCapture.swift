import Foundation

enum CommandOutputCapture {
    struct Result {
        let terminationStatus: Int32
        let stdout: Data
        let stderr: Data
    }

    static func run(
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval? = nil
    ) -> Result? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executablePath)
        task.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe

        final class DataBox {
            var data = Data()
        }

        let stdoutBox = DataBox()
        let stderrBox = DataBox()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stdoutBox.data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stderrBox.data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        do {
            try task.run()
        } catch {
            return nil
        }

        if let timeout {
            let deadline = Date().addingTimeInterval(timeout)
            while task.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.03)
            }
            if task.isRunning {
                task.terminate()
            }
        }

        task.waitUntilExit()
        group.wait()

        return Result(
            terminationStatus: task.terminationStatus,
            stdout: stdoutBox.data,
            stderr: stderrBox.data
        )
    }
}
