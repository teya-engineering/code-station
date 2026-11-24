import Foundation
import Testing

@main
struct TestMain {
    static func main() {
        guard let option = CommandLine.arguments.firstIndex(of: "--test-bundle-path"),
              CommandLine.arguments.indices.contains(option + 1) else {
            fatalError("Missing --test-bundle-path")
        }
        guard dlopen(CommandLine.arguments[option + 1], RTLD_LAZY | RTLD_LOCAL) != nil else {
            fatalError(String(cString: dlerror()))
        }
        Task {
            await Testing.__swiftPMEntryPoint() as Never
        }
        // AppKit can stop the main run loop before the test task finishes. An async
        // main would then exit successfully: https://github.com/swiftlang/swift/issues/91716
        while true {
            CFRunLoopRun()
        }
    }
}
