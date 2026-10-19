import Foundation
import CodeStationCore

enum MobilePage {
    static var data: Data {
        read(extension: "html") ?? Data("Mobile session page is missing.".utf8)
    }

    static func resource(_ path: String) -> LANResource? {
        let ext: String
        let contentType: String
        switch path {
        case "/assets/mobile-session.css":
            ext = "css"
            contentType = "text/css; charset=utf-8"
        case "/assets/mobile-session.js":
            ext = "js"
            contentType = "text/javascript; charset=utf-8"
        default: return nil
        }
        guard let data = read(extension: ext) else { return nil }
        return LANResource(data: data, contentType: contentType)
    }

    private static func read(extension ext: String) -> Data? {
        guard let url = AppResources.bundle.url(forResource: "mobile-session", withExtension: ext) else { return nil }
        return try? Data(contentsOf: url)
    }
}
