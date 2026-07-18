import Foundation

enum AIToolArgumentValueType {
    case string
    case integer
    case stringArray

    var schema: ModelDirectiveResponseSchema {
        switch self {
        case .string:
            return ModelDirectiveResponseSchema(type: "string", nullable: true)
        case .integer:
            return ModelDirectiveResponseSchema(type: "integer", nullable: true)
        case .stringArray:
            return ModelDirectiveResponseSchema(
                type: "array",
                nullable: true,
                items: ModelDirectiveResponseSchema(type: "string")
            )
        }
    }

    var promptLabel: String {
        switch self {
        case .string:
            return "string"
        case .integer:
            return "integer"
        case .stringArray:
            return "string[]"
        }
    }

    var openAISchema: [String: Any] {
        switch self {
        case .string:
            return ["type": "string"]
        case .integer:
            return ["type": "integer"]
        case .stringArray:
            return [
                "type": "array",
                "items": ["type": "string"]
            ]
        }
    }
}

struct AIToolArgumentDefinition {
    let name: String
    let type: AIToolArgumentValueType
    let description: String
    let isRequired: Bool

    init(name: String, type: AIToolArgumentValueType, description: String, isRequired: Bool = false) {
        self.name = name
        self.type = type
        self.description = description
        self.isRequired = isRequired
    }
}

struct AIToolDefinition {
    let name: String
    let summary: String
    let arguments: [AIToolArgumentDefinition]
}

enum AIToolCatalog {
    static let definitions: [AIToolDefinition] = [
        AIToolDefinition(
            name: "conversation_search",
            summary: "AI Studio の過去会話と承認済みメモリーを検索します。",
            arguments: [
                AIToolArgumentDefinition(name: "query", type: .string, description: "単一の検索語"),
                AIToolArgumentDefinition(name: "queries", type: .stringArray, description: "複数の検索語"),
                AIToolArgumentDefinition(name: "limit", type: .integer, description: "必要な件数")
            ]
        ),
        AIToolDefinition(
            name: "external_search",
            summary: "外部情報を確認します。1ラウンドごとに 3〜10 件の queries を作れます。",
            arguments: [
                AIToolArgumentDefinition(name: "query", type: .string, description: "単一の検索語"),
                AIToolArgumentDefinition(name: "queries", type: .stringArray, description: "複数の検索語"),
                AIToolArgumentDefinition(name: "stopCondition", type: .string, description: "どの条件で検索を止めるか")
            ]
        ),
        AIToolDefinition(
            name: "python_exec",
            summary: "制限版 Python を実行します。",
            arguments: [
                AIToolArgumentDefinition(name: "code", type: .string, description: "実行する Python コード", isRequired: true)
            ]
        ),
        AIToolDefinition(
            name: "table_builder",
            summary: "JSON / CSV / TSV / 箇条書き / 項目: 値 から表の下書きを作ります。",
            arguments: [
                AIToolArgumentDefinition(name: "source", type: .string, description: "表の元データ", isRequired: true)
            ]
        ),
        AIToolDefinition(
            name: "current_time",
            summary: "現在の日時を返します。",
            arguments: [
                AIToolArgumentDefinition(name: "query", type: .string, description: "用途メモ")
            ]
        ),
        AIToolDefinition(
            name: "calculator",
            summary: "数式を計算します。",
            arguments: [
                AIToolArgumentDefinition(name: "expression", type: .string, description: "計算式", isRequired: true)
            ]
        )
    ]

    static var toolNames: [String] {
        definitions.map(\.name)
    }

    static func containsTool(named name: String) -> Bool {
        definitions.contains { $0.name == name }
    }

    static func definition(named name: String) -> AIToolDefinition? {
        definitions.first { $0.name == name }
    }

    static func displayName(forToolNamed toolName: String) -> String {
        switch toolName {
        case "conversation_search":
            return "会話検索"
        case "external_search":
            return "外部検索"
        case "python_exec":
            return "Python"
        case "table_builder":
            return "表作成"
        case "current_time":
            return "現在時刻"
        case "calculator":
            return "計算"
        default:
            return toolName
        }
    }

    static func summary(forToolNamed toolName: String) -> String {
        definition(named: toolName)?.summary ?? toolName
    }

    static func enabledDefinitions(named enabledToolNames: [String]) -> [AIToolDefinition] {
        let enabled = Set(enabledToolNames)
        return definitions.filter { enabled.contains($0.name) }
    }

    static func argument(named argumentName: String, forToolNamed toolName: String) -> AIToolArgumentDefinition? {
        definition(named: toolName)?.arguments.first { $0.name == argumentName }
    }

    static func requiredArgumentNames(forToolNamed toolName: String) -> Set<String> {
        Set(
            definition(named: toolName)?
                .arguments
                .filter(\.isRequired)
                .map(\.name) ?? []
        )
    }

    static func acceptsArgument(named argumentName: String, forToolNamed toolName: String) -> Bool {
        argument(named: argumentName, forToolNamed: toolName) != nil
    }

    static func requiresNonEmptyQuery(forToolNamed toolName: String) -> Bool {
        switch toolName {
        case "conversation_search", "external_search":
            return true
        default:
            return false
        }
    }

    static func toolCallArgumentSchemaProperties() -> [String: ModelDirectiveResponseSchema] {
        var properties: [String: ModelDirectiveResponseSchema] = [:]
        for definition in definitions {
            for argument in definition.arguments {
                properties[argument.name] = argument.type.schema
            }
        }
        return properties
    }

    static func cloudInstructionLines() -> [String] {
        var lines: [String] = []
        lines.append("使える app 側ツールは \(toolNames.joined(separator: " / ")) です。")
        for definition in definitions {
            lines.append("- \(definition.name): \(definition.summary) 引数: \(argumentSummary(for: definition))")
        }
        return lines
    }

    static func localStructuredPromptSection(
        enabledToolNames: [String] = AIToolCatalog.toolNames,
        strictJSONToolCalls: Bool = true,
        allowDirectAnswersWithoutTools: Bool = true
    ) -> String {
        let activeDefinitions = enabledDefinitions(named: enabledToolNames)
        if activeDefinitions.isEmpty {
            return """
            function calling setup:
            - 日本語で答えてください。
            - 現在使える関数はありません。このターンでは functionCall / functionCalls を返さず、最終回答だけを返してください。
            """
        }

        let functionDefinitions = activeDefinitions.map { definition in
            let properties = definition.arguments.map { argument in
                """
                "\(argument.name)": {
                  "type": "\(argument.type.promptLabel)",
                  "description": "\(argument.description)"
                }
                """
            }.joined(separator: ",\n")

            let parametersBlock: String
            if definition.arguments.isEmpty {
                parametersBlock = "{}"
            } else {
                parametersBlock = """
                {
                  "type": "object",
                  "properties": {
                \(indent(properties, spaces: 4))
                  }
                }
                """
            }

            return """
            {
              "name": "\(definition.name)",
              "description": "\(definition.summary)",
              "parameters": \(parametersBlock)
            }
            """
        }.joined(separator: ",\n")

        let toolCallingLine = strictJSONToolCalls
            ? "- 関数が必要なターンでは JSON だけを返してください。"
            : "- 関数が必要なターンでは JSON の functionCall / functionCalls を最優先で返してください。"
        let directAnswerLine = allowDirectAnswersWithoutTools
            ? "- 関数が不要なら最終回答だけを返してください。"
            : "- 不確かな時は即答せず、使える関数で確認してから答えてください。"
        let noToolLine = activeDefinitions.isEmpty
            ? "- 現在使える関数はありません。このターンでは最終回答だけを返してください。"
            : nil

        return """
        function calling setup:
        - 日本語で答えてください。
        - Thinking 中の関数呼び出しは最大3回です。必要性の高い web 検索・Python・計算だけを選んでください。
        \(toolCallingLine)
        - 単発:
          {"functionCall":{"name":"tool_name","arguments":{"query":"..."}}}
        - 複数:
          {"functionCalls":[{"name":"tool_name","arguments":{"query":"..."}}]}
        \(directAnswerLine)
        \(noToolLine ?? "")

        function definitions:
        [
        \(indent(functionDefinitions, spaces: 2))
        ]
        """
    }

    static func localToolResultInstruction(hasToolResults: Bool) -> String {
        hasToolResults
            ? "function results を見て、次の function call JSON か最終回答だけを返してください。"
            : "必要なら JSON の functionCall を返してください。"
    }

    static func openAIToolPayloads(
        enabledToolNames: [String] = AIToolCatalog.toolNames
    ) -> [[String: Any]] {
        enabledDefinitions(named: enabledToolNames).map { definition in
            let properties = definition.arguments.reduce(into: [String: Any]()) { partialResult, argument in
                partialResult[argument.name] = argument.type.openAISchema.merging([
                    "description": argument.description
                ]) { current, _ in current }
            }
            let required = definition.arguments
                .filter(\.isRequired)
                .map(\.name)

            var parameters: [String: Any] = [
                "type": "object",
                "properties": properties
            ]
            if !required.isEmpty {
                parameters["required"] = required
            }

            return [
                "type": "function",
                "function": [
                    "name": definition.name,
                    "description": definition.summary,
                    "parameters": parameters
                ]
            ]
        }
    }

    private static func argumentSummary(for definition: AIToolDefinition) -> String {
        guard !definition.arguments.isEmpty else {
            return "なし"
        }
        return definition.arguments
            .map { "\($0.name)(\($0.type.promptLabel))" }
            .joined(separator: ", ")
    }

    private static func indent(_ text: String, spaces: Int) -> String {
        let prefix = String(repeating: " ", count: spaces)
        return text
            .components(separatedBy: .newlines)
            .map { $0.isEmpty ? $0 : prefix + $0 }
            .joined(separator: "\n")
    }
}
