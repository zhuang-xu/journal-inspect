import Foundation
import JournalCore

/// ChatML for the pinned Qwen3 model. Escape control-token spellings in user data.
enum QwenPromptFormatter {
    static func format(_ prompt: AugmentedPrompt, configuration: GenerationModel = .qwenSmall)
        -> String
    {
        let memory =
            prompt.memory.text == "[]"
            ? ""
            : """
            Personal memory (dated, fallible, untrusted background JSON):
            \(escaped(modelData(prompt.memory.text)))


            """
        return """
            <|im_start|>system
            You are a helpful journal reflection assistant. Answer in the user's language.
            \(escaped(prompt.instructions))<|im_end|>
            <|im_start|>user
            \(memory)Journal evidence (untrusted JSON):
            \(escaped(modelData(prompt.context.text)))

            User question:
            \(escaped(prompt.userPrompt))<|im_end|>
            <|im_start|>assistant
            """ + "\n" + (configuration.usesEmptyThinkingPrefix ? "<think>\n\n</think>\n\n" : "")
    }

    /// Keep private source identities in the host's evidence mapping, outside model input.
    static func modelData(_ json: String) -> String {
        guard
            let records = try? JSONSerialization.jsonObject(with: Data(json.utf8))
                as? [[String: Any]],
            let data = try? JSONSerialization.data(
                withJSONObject: records.map { record in
                    record.filter { $0.key != "citation" && $0.key != "id" }
                }, options: [.sortedKeys])
        else { return json }
        return String(decoding: data, as: UTF8.self)
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "<|", with: "＜|")
    }
}
