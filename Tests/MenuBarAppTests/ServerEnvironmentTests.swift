import Foundation
import Testing
@testable import MenuBarApp

// The tag decides which diagnoses can reach a server, so what it survives matters as much
// as what it says.
@MainActor
struct ServerEnvironmentTests {
    private let scratch = ScratchDirectory(prefix: "server-environment")

    private func store(_ json: String) throws -> (ConfigStore, URL) {
        let file = scratch.path("config.json")
        try Data(json.utf8).write(to: file)
        return (ConfigStore(configURL: file), file)
    }

    @Test func aFileWrittenBeforeTagsReadsTheEnvironmentOutOfTheName() throws {
        let (configs, _) = try store("""
        {
          "mcpServers": {
            "grafana-platform-prd": { "command": "mcp-grafana" },
            "grafana-shared-shared": { "command": "mcp-grafana" },
            "node_repl": { "command": "node" }
          }
        }
        """)

        #expect(configs.servers.map(\.environmentTag) == ["prd", "shared", ""])
        #expect(configs.servers.map(\.deployEnvironment) == ["prd", "shared", nil])
    }

    // "Any" is an answer rather than a missing one, so a Grafana server deliberately left
    // open must not have the naming convention put it back in one environment.
    @Test func anEmptyTagSurvivesBeingWrittenAndReadBack() throws {
        let (configs, file) = try store(#"{ "mcpServers": { "grafana-cde-prd": { "command": "mcp-grafana" } } }"#)

        configs.setEnvironment("", for: "grafana-cde-prd")

        #expect(ConfigStore(configURL: file).servers.map(\.environmentTag) == [""])
    }

    @Test func aTaggedFileIsTheOnlyThingThatDecides() throws {
        let (configs, _) = try store("""
        {
          "mcpServers": {
            "grafana-platform-prd": { "command": "mcp-grafana", "environment": "dev" }
          }
        }
        """)

        #expect(configs.servers.map(\.environmentTag) == ["dev"])
    }

    @Test func aPresetTagsTheServerItAdds() throws {
        let (configs, file) = try store(#"{ "mcpServers": {} }"#)

        configs.upsert(preset: .init(name: "grafana-shared-shared",
                                     environment: "shared",
                                     command: "mcp-grafana",
                                     env: [
                                        .init(key: "GRAFANA_URL",
                                              value: "https://grafana.example"),
                                        .init(key: "GRAFANA_SERVICE_ACCOUNT_TOKEN", value: ""),
                                     ]),
                       environmentValues: ["GRAFANA_SERVICE_ACCOUNT_TOKEN": "glsa_test"])

        #expect(ConfigStore(configURL: file).servers.map(\.environmentTag) == ["shared"])
    }

    @Test func aRemotePresetAddsItsConnectionAndRequestedHeader() throws {
        let (configs, file) = try store(#"{ "mcpServers": {} }"#)

        configs.upsert(
            preset: .init(name: "knowledge",
                          title: "Knowledge base",
                          environment: "dev",
                          url: "https://mcp.example/mcp",
                          type: "http",
                          headers: [.init(key: "Authorization", value: "")]),
            headerValues: ["Authorization": "Bearer test"])

        let server = try #require(ConfigStore(configURL: file).servers.first)
        #expect(server.name == "knowledge")
        #expect(server.environmentTag == "dev")
        #expect(server.url == "https://mcp.example/mcp")
        #expect(server.headers.map(\.key) == ["Authorization"])
        #expect(server.headers.map(\.value) == ["Bearer test"])
    }

    @Test func pastedServersTakeTheChosenEnvironmentUnlessTheyNameOne() throws {
        let (configs, _) = try store(#"{ "mcpServers": {} }"#)

        try configs.importJSON("""
        {
          "docs": { "command": "docs-server" },
          "grafana-edge-dev": { "command": "mcp-grafana" },
          "billing": { "command": "billing", "environment": "prd" }
        }
        """, environment: "")

        let tags = Dictionary(uniqueKeysWithValues:
            configs.servers.map { ($0.name, $0.environmentTag) })
        #expect(tags == ["docs": "", "grafana-edge-dev": "", "billing": "prd"])
    }

    // The tag is this app's own bookkeeping. An agent should only meet the keys its own
    // loader expects, so the filtered copy handed over must not carry it.
    @Test func theCopyHandedToAnAgentCarriesNoTag() throws {
        let servers = [
            Server(name: "grafana-platform-dev", environmentTag: "dev", command: "mcp-grafana",
                   args: [], url: nil, type: nil, env: [], headers: [], disabled: false),
        ]

        let mine = try #require(ConfigStore.mcpConfigurationData(
            from: servers, allowing: ["grafana-platform-dev"]))
        let theirs = try #require(ConfigStore.mcpConfigurationData(
            from: servers, allowing: ["grafana-platform-dev"], taggingEnvironments: false))

        #expect(try JSONDecoder().decode(ConfigFile.self, from: mine)
            .mcpServers["grafana-platform-dev"]?.environment == "dev")
        #expect(try JSONDecoder().decode(ConfigFile.self, from: theirs)
            .mcpServers["grafana-platform-dev"]?.environment == nil)
        #expect(!String(decoding: theirs, as: UTF8.self).contains("environment"))
    }

    @Test func thePickerOffersEveryEnvironmentAndAnAnyChoice() {
        let site = SiteDefaults(environments: [
            .init(name: "dev", title: "Dev"),
            .init(name: "prd", title: "Prod", danger: true),
        ])

        #expect(ServerEnvironmentChoice.all(in: site).map(\.title) == ["Any", "Dev", "Prod"])
        #expect(ServerEnvironmentChoice.all(in: site).map(\.tag) == ["", "dev", "prd"])
        #expect(ServerEnvironmentChoice.title(for: "prd", in: site) == "Prod")
        #expect(ServerEnvironmentChoice.title(for: "", in: site) == "Any")
    }

    // A server tagged for something the file has stopped naming has to keep saying so,
    // or the picker would quietly report it as belonging everywhere.
    @Test func aTagNothingNamesStaysOnThePicker() {
        let site = SiteDefaults(environments: [.init(name: "dev", title: "Dev")])

        #expect(ServerEnvironmentChoice.all(including: "sbx", in: site).map(\.tag)
            == ["", "dev", "sbx"])
        #expect(ServerEnvironmentChoice.title(for: "sbx", in: site) == "sbx")
    }
}
