import Foundation
import ZIPFoundation

// MARK: - 会议记录 Word 模板：找出要填的格子，按 AI 给的内容填进去，生成新的 .docx

struct TemplateField: Codable, Hashable, Identifiable {
    var id: String          // f1, f2 ...
    var label: String       // 「会议主题」
    var context: String     // 所在行的其他文字，帮助 AI 区分同名栏目
}

struct WordTemplate: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var fileName: String
    var fields: [TemplateField]
    var addedAt = Date()

    var fileURL: URL { TemplateStore.dir.appendingPathComponent(fileName) }
}

/// 某条录音填好的表
struct FilledForm: Codable, Hashable {
    var templateID: UUID
    var templateName: String
    var values: [String: String]   // 字段 id → 内容
    var fields: [TemplateField]
    var fileName: String           // Documents/Filled 下的文件名
    var filledAt = Date()
    var model: String = ""

    var fileURL: URL { TemplateStore.filledDir.appendingPathComponent(fileName) }
}

enum TemplateStore {
    static var dir: URL { make("Templates") }
    static var filledDir: URL { make("Filled") }

    private static func make(_ name: String) -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent(name, isDirectory: true)
        if !FileManager.default.fileExists(atPath: d.path) {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        return d
    }

    private static let key = "wordTemplates"
    private static let defaultKey = "defaultWordTemplate"
    static let autoFillKey = "autoFillMeetingForm"

    static var all: [WordTemplate] {
        get {
            guard let d = UserDefaults.standard.data(forKey: key),
                  let t = try? JSONDecoder().decode([WordTemplate].self, from: d) else { return [] }
            return t
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }

    static var defaultID: UUID? {
        get { UserDefaults.standard.string(forKey: defaultKey).flatMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: defaultKey) }
    }

    static var defaultTemplate: WordTemplate? {
        let list = all
        return list.first { $0.id == defaultID } ?? list.first
    }

    static var autoFill: Bool { UserDefaults.standard.bool(forKey: autoFillKey) }

    /// 导入一个 .docx 模板
    static func importTemplate(_ src: URL) throws -> WordTemplate {
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }
        guard src.pathExtension.lowercased() == "docx" else {
            throw VNError("只支持 .docx 格式的 Word 文件。如果是 .doc 或 WPS 格式，先在 WPS/Word 里另存为 .docx")
        }
        let name = "\(UUID().uuidString).docx"
        let dest = dir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: src, to: dest)
        let xml = try DocxIO.readDocumentXML(dest)
        let fields = DocxForm.detectFields(xml).map(\.field)
        guard !fields.isEmpty else {
            try? FileManager.default.removeItem(at: dest)
            throw VNError("没在这个文档里找到要填的空格子。模板要有表格：左边或上面写栏目名（比如「会议主题」），旁边留空格子。")
        }
        let t = WordTemplate(name: src.deletingPathExtension().lastPathComponent, fileName: name, fields: fields)
        var list = all
        list.append(t)
        all = list
        if defaultID == nil { defaultID = t.id }
        return t
    }

    static func remove(_ t: WordTemplate) {
        try? FileManager.default.removeItem(at: t.fileURL)
        all = all.filter { $0.id != t.id }
        if defaultID == t.id { defaultID = all.first?.id }
    }
}

// MARK: - docx 读写

enum DocxIO {
    static func readDocumentXML(_ url: URL) throws -> String {
        let archive = try Archive(url: url, accessMode: .read)
        guard let entry = archive["word/document.xml"] else { throw VNError("这不是有效的 Word 文件") }
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        guard let s = String(data: data, encoding: .utf8) else { throw VNError("读不出文档内容") }
        return s
    }

    /// 复制模板，把 document.xml 换成填好的内容
    static func write(template: URL, documentXML: String, to out: URL) throws {
        let src = try Archive(url: template, accessMode: .read)
        try? FileManager.default.removeItem(at: out)
        let dst = try Archive(url: out, accessMode: .create)
        for entry in src {
            var data = Data()
            if entry.path == "word/document.xml" {
                data = Data(documentXML.utf8)
            } else if entry.type == .file {
                _ = try src.extract(entry) { data.append($0) }
            } else {
                continue
            }
            let payload = data
            try dst.addEntry(with: entry.path, type: .file, uncompressedSize: Int64(payload.count),
                             compressionMethod: .deflate) { position, size in
                let start = Int(position)
                return payload.subdata(in: start..<min(start + size, payload.count))
            }
        }
    }
}

// MARK: - 找格子、填格子（直接处理 document.xml 文本）

enum DocxForm {
    struct Cell {
        var range: Range<String.Index>
        var text: String
        var row: Int
        var col: Int
        var table: Int
    }

    struct Slot {
        var field: TemplateField
        var cellRange: Range<String.Index>
        var inline: Bool          // true = 栏目名和内容在同一个格子（「会议内容：」下面写）
        var styleFrom: Range<String.Index>?
    }

    /// 扫出所有表格格子（不处理嵌套表格里的格子）
    static func cells(_ xml: String) -> [Cell] {
        var out: [Cell] = []
        var table = -1, row = -1, col = -1
        var depth = 0
        var i = xml.startIndex
        var cellStart: String.Index?
        while let lt = xml[i...].firstIndex(of: "<") {
            guard let gt = xml[lt...].firstIndex(of: ">") else { break }
            let tag = xml[lt...gt]
            if tag.hasPrefix("<w:tbl>") || tag.hasPrefix("<w:tbl ") {
                depth += 1
                if depth == 1 { table += 1; row = -1 }
            } else if tag.hasPrefix("</w:tbl>") {
                depth -= 1
            } else if depth == 1 && (tag.hasPrefix("<w:tr>") || tag.hasPrefix("<w:tr ")) {
                row += 1; col = -1
            } else if depth == 1 && (tag.hasPrefix("<w:tc>") || tag.hasPrefix("<w:tc ")) {
                col += 1
                cellStart = lt
            } else if depth == 1 && tag.hasPrefix("</w:tc>"), let s = cellStart {
                let r = s..<xml.index(after: gt)
                out.append(Cell(range: r, text: text(of: String(xml[r])), row: row, col: col, table: table))
                cellStart = nil
            }
            i = xml.index(after: gt)
        }
        return out
    }

    static func text(of fragment: String) -> String {
        var s = ""
        var rest = fragment[...]
        while let r = rest.range(of: "<w:t") {
            guard let close = rest[r.upperBound...].firstIndex(of: ">") else { break }
            let after = rest.index(after: close)
            if rest[rest.index(before: close)] == "/" { rest = rest[after...]; continue }  // <w:t/>
            // 排除 <w:tab> <w:tbl> 之类
            let next = rest[r.upperBound]
            if next != ">" && next != " " { rest = rest[after...]; continue }
            guard let end = rest[after...].range(of: "</w:t>") else { break }
            s += rest[after..<end.lowerBound]
            rest = rest[end.upperBound...]
        }
        return unescape(s)
    }

    static func detectFields(_ xml: String) -> [Slot] {
        let all = cells(xml)
        var byPos: [String: Cell] = [:]
        for c in all { byPos["\(c.table)-\(c.row)-\(c.col)"] = c }
        var slots: [Slot] = []
        var used = Set<String>()

        func clean(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "：:　 "))
        }

        for c in all {
            let t = c.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = "\(c.table)-\(c.row)-\(c.col)"
            // 纵向合并的续格不算
            let cellXML = xml[c.range]
            if cellXML.contains("<w:vMerge/>") || cellXML.contains("w:vMerge w:val=\"continue\"") { continue }
            if t.isEmpty || t.allSatisfy({ $0 == "_" || $0 == " " }) {
                // 空格子：栏目名在左边，没有就看上面
                var label: Cell?
                var k = c.col - 1
                while k >= 0 {
                    if let l = byPos["\(c.table)-\(c.row)-\(k)"], !clean(l.text).isEmpty { label = l; break }
                    k -= 1
                }
                if label == nil, let up = byPos["\(c.table)-\(c.row - 1)-\(c.col)"], !clean(up.text).isEmpty {
                    label = up
                }
                guard let l = label, clean(l.text).count <= 20 else { continue }
                let rowText = all.filter { $0.table == c.table && $0.row == c.row && $0.col != c.col }
                    .map { clean($0.text) }.filter { !$0.isEmpty }.joined(separator: " / ")
                slots.append(Slot(field: TemplateField(id: "", label: clean(l.text), context: rowText),
                                  cellRange: c.range, inline: false, styleFrom: l.range))
                used.insert(key)
            } else if (t.hasSuffix("：") || t.hasSuffix(":")), clean(t).count <= 20 {
                // 「会议内容：」这种，内容写在同一格子里
                let right = byPos["\(c.table)-\(c.row)-\(c.col + 1)"]
                if right == nil || !clean(right!.text).isEmpty {
                    slots.append(Slot(field: TemplateField(id: "", label: clean(t), context: ""),
                                      cellRange: c.range, inline: true, styleFrom: c.range))
                }
            }
        }
        // 按顺序编号；同名栏目加序号
        var seen: [String: Int] = [:]
        for i in slots.indices {
            slots[i].field.id = "f\(i + 1)"
            let n = (seen[slots[i].field.label] ?? 0) + 1
            seen[slots[i].field.label] = n
            if n > 1 { slots[i].field.label += "（\(n)）" }
        }
        return slots
    }

    /// 把内容填进去，返回新的 document.xml
    static func fill(_ xml: String, values: [String: String]) -> String {
        let slots = detectFields(xml)
        var out = xml
        // 从后往前替换，前面的位置不会变
        for slot in slots.reversed() {
            guard let raw = values[slot.field.id]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { continue }
            let cell = String(xml[slot.cellRange])
            let rPr = slot.styleFrom.flatMap { firstRunProps(String(xml[$0])) } ?? ""
            let run = makeRun(raw, rPr: rPr)
            var newCell = cell
            if slot.inline {
                // 在格子末尾加一段
                if let end = newCell.range(of: "</w:tc>", options: .backwards) {
                    newCell.replaceSubrange(end, with: "<w:p>\(run)</w:p></w:tc>")
                }
            } else if let selfClosing = newCell.range(of: "<w:p\\b[^>]*/>", options: .regularExpression) {
                let tag = String(newCell[selfClosing])
                let open = String(tag.dropLast(2)) + ">"
                newCell.replaceSubrange(selfClosing, with: open + run + "</w:p>")
            } else if let pEnd = newCell.range(of: "</w:p>") {
                // 去掉原来的下划线占位
                let before = String(newCell[..<pEnd.lowerBound])
                    .replacingOccurrences(of: "<w:t>_+</w:t>", with: "<w:t></w:t>", options: .regularExpression)
                newCell = before + run + String(newCell[pEnd.lowerBound...])
            } else if let end = newCell.range(of: "</w:tc>", options: .backwards) {
                newCell.replaceSubrange(end, with: "<w:p>\(run)</w:p></w:tc>")
            }
            out.replaceSubrange(slot.cellRange, with: newCell)
        }
        return out
    }

    private static func firstRunProps(_ fragment: String) -> String? {
        guard let r = fragment.range(of: "<w:rPr>"),
              let e = fragment[r.upperBound...].range(of: "</w:rPr>") else { return nil }
        var props = String(fragment[r.lowerBound..<e.upperBound])
        // 内容不要加粗
        props = props.replacingOccurrences(of: "<w:b/>", with: "").replacingOccurrences(of: "<w:bCs/>", with: "")
        return props
    }

    private static func makeRun(_ text: String, rPr: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let body = lines.map { "<w:t xml:space=\"preserve\">\(escape($0))</w:t>" }.joined(separator: "<w:br/>")
        return "<w:r>\(rPr)\(body)</w:r>"
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

// MARK: - 让 AI 给每个栏目写内容

enum FormFiller {
    static func fill(template: WordTemplate, rec: Recording, ref: ModelRef,
                     onProgress: ((String, Int) -> Void)? = nil) async throws -> FilledForm {
        guard let key = Keychain.get(ref.provider.keyName) else {
            throw VNError("还没填 \(ref.provider.label) 的 API Key")
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日 EEEE HH:mm"
        let fieldList = template.fields.map { fd in
            "\(fd.id)：\(fd.label)" + (fd.context.isEmpty ? "" : "（同一行还有：\(fd.context)）")
        }.joined(separator: "\n")

        let material: String
        if !rec.summary.isEmpty {
            material = "【AI 整理稿】\n" + OrganizedParser.stripMarkers(rec.summary) + "\n\n【转写原文】\n" + rec.transcript
        } else {
            material = "【转写原文】\n" + rec.transcript
        }

        let system = """
        你是会议记录员。用户有一张固定格式的会议记录表，请根据录音内容填写表里的每一个栏目。
        要求：
        1. 只输出一个 JSON 对象，键是栏目编号（f1、f2…），值是要填进去的文字，不要输出任何其他内容。
        2. 内容要正式、简洁，像正式会议记录的写法；多条内容用「1. 2. 3.」编号并用 \\n 换行。
        3. 录音里没提到的栏目填「未提及」；日期、时间如果录音没说，用录音时间：\(f.string(from: rec.createdAt))，时长约 \(Int(rec.duration / 60) + 1) 分钟。
        4. 「记录人」「审核人」「签字」这类需要本人签的栏目留空字符串。
        5. 不要编造录音里没有的人名、数字和结论。
        """
        let user = "会议记录表的栏目：\n\(fieldList)\n\n录音内容：\n\(material)"
        var body: [String: Any] = [
            "model": ref.model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "temperature": 0.2,
        ]
        if ref.provider == .zhipu { body["reasoning_effort"] = "low" }
        let out = try await OpenAIClient.chatStream(baseURL: AppConfig.llmBaseURL(ref.provider), apiKey: key,
                                                    body: body, timeout: 600, onDelta: onProgress ?? { _, _ in })
        let values = try parseJSON(Organizer.clean(out))

        let xml = try DocxIO.readDocumentXML(template.fileURL)
        let filledXML = DocxForm.fill(xml, values: values)
        let safeTitle = rec.title.replacingOccurrences(of: "/", with: "-").prefix(40)
        let name = "\(safeTitle)-\(template.name).docx"
        let outURL = TemplateStore.filledDir.appendingPathComponent("\(rec.id.uuidString)-\(template.id.uuidString).docx")
        try DocxIO.write(template: template.fileURL, documentXML: filledXML, to: outURL)
        _ = name
        return FilledForm(templateID: template.id, templateName: template.name, values: values,
                          fields: template.fields, fileName: outURL.lastPathComponent, model: ref.model)
    }

    static func parseJSON(_ s: String) throws -> [String: String] {
        var t = s
        if let a = t.firstIndex(of: "{"), let b = t.lastIndex(of: "}") { t = String(t[a...b]) }
        guard let d = t.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
            throw VNError("模型返回的内容不是表格数据，换个模型再试")
        }
        var out: [String: String] = [:]
        for (k, v) in obj {
            if let s = v as? String { out[k] = s }
            else if let arr = v as? [Any] { out[k] = arr.map { "\($0)" }.joined(separator: "\n") }
            else { out[k] = "\(v)" }
        }
        return out
    }

    /// 导出时用好看的文件名复制一份
    static func exportCopy(_ form: FilledForm, title: String) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "\(title.replacingOccurrences(of: "/", with: "-").prefix(40))-\(form.templateName).docx"
        let dest = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: form.fileURL, to: dest)
            return dest
        } catch {
            return nil
        }
    }
}
