import Foundation

// Every git the app starts runs the same way: no terminal behind it, nobody to answer a
// prompt, and its messages read back by code. Building the environment in one place
// keeps a new caller from quietly missing one of these.
enum GitEnvironment {
    static func nonInteractive(searchPath: String,
                               base: [String: String] = ProcessInfo.processInfo.environment)
        -> [String: String] {
        var environment = base
        // A Finder launched app has almost no PATH, so git and its helpers are found
        // through the same search path the app uses for everything else.
        environment["PATH"] = searchPath
        // No tty here, so make sure git can never sit waiting for a password or an editor.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_PAGER"] = "cat"
        // A few answers are only available as the sentence git prints for a person, and
        // git translates those. Pinning the locale keeps them in the words the readers
        // match against, whatever language the Mac is set to.
        environment["LC_ALL"] = "C"
        return environment
    }
}
