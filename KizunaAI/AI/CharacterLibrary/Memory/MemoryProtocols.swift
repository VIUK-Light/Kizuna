/*
仕様:
- 役割: メモリーの「選別」と「抽出」の Protocol。
- 主な型: MemorySelecting, MemorySummarizing.
*/

import Foundation

protocol MemorySelecting: AnyObject {
    /// 候補メモリーをユーザー発話への関連度で並べ替え、上位 N 件を返す。
    func select(query: String, candidates: [CharacterMemory], topK: Int) async -> [CharacterMemory]
}

protocol MemorySummarizing: AnyObject {
    /// 1 往復から保存すべき新規 fact を抽出する。
    /// 何も抽出すべきものがなければ空配列を返す。
    func extract(userText: String, assistantText: String, character: CharacterProfile) async -> [CharacterMemory]
}
