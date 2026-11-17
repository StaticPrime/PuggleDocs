import Foundation

/// `styles.xml` describing PuggleDocs' named styles, so other editors recognise titles and headings.
enum DocxStyles {
    static var stylesXML: String {
        let normal = NamedStyle.normal.definition
        let family = DocxWriter.escape(normal.fontFamily)
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        xml += "<w:styles xmlns:w=\"\(DocxWriter.wNamespace)\">"
        xml += "<w:docDefaults><w:rPrDefault><w:rPr>"
        xml += "<w:rFonts w:ascii=\"\(family)\" w:hAnsi=\"\(family)\" w:eastAsia=\"\(family)\" w:cs=\"\(family)\"/>"
        xml += "<w:sz w:val=\"\(Int(normal.fontSize * 2))\"/><w:szCs w:val=\"\(Int(normal.fontSize * 2))\"/><w:lang w:val=\"en\"/>"
        xml += "</w:rPr></w:rPrDefault><w:pPrDefault><w:pPr>"
        xml += "<w:spacing w:after=\"0\" w:line=\"\(Int(normal.lineSpacing * 240))\" w:lineRule=\"auto\"/>"
        xml += "</w:pPr></w:pPrDefault></w:docDefaults>"

        for style in NamedStyle.allCases {
            xml += styleXML(style)
        }

        xml += "<w:style w:type=\"character\" w:default=\"1\" w:styleId=\"DefaultParagraphFont\"><w:name w:val=\"Default Paragraph Font\"/>"
        xml += "<w:uiPriority w:val=\"1\"/><w:semiHidden/><w:unhideWhenUsed/></w:style>"
        xml += "<w:style w:type=\"character\" w:styleId=\"Hyperlink\"><w:name w:val=\"Hyperlink\"/><w:basedOn w:val=\"DefaultParagraphFont\"/>"
        xml += "<w:uiPriority w:val=\"99\"/><w:unhideWhenUsed/><w:rPr><w:color w:val=\"\(ColorPalette.linkHex)\"/><w:u w:val=\"single\"/></w:rPr></w:style>"
        xml += "<w:style w:type=\"table\" w:default=\"1\" w:styleId=\"TableNormal\"><w:name w:val=\"Normal Table\"/><w:uiPriority w:val=\"99\"/>"
        xml += "<w:semiHidden/><w:unhideWhenUsed/><w:tblPr><w:tblInd w:w=\"0\" w:type=\"dxa\"/><w:tblCellMar>"
        xml += "<w:top w:w=\"0\" w:type=\"dxa\"/><w:left w:w=\"108\" w:type=\"dxa\"/><w:bottom w:w=\"0\" w:type=\"dxa\"/><w:right w:w=\"108\" w:type=\"dxa\"/>"
        xml += "</w:tblCellMar></w:tblPr></w:style>"
        xml += "<w:style w:type=\"numbering\" w:default=\"1\" w:styleId=\"NoList\"><w:name w:val=\"No List\"/><w:uiPriority w:val=\"99\"/>"
        xml += "<w:semiHidden/><w:unhideWhenUsed/></w:style>"
        xml += "</w:styles>"
        return xml
    }

    static func styleXML(_ style: NamedStyle) -> String {
        let definition = style.definition
        let isDefault = style == .normal
        var xml = "<w:style w:type=\"paragraph\"\(isDefault ? " w:default=\"1\"" : "") w:styleId=\"\(style.docxStyleID)\">"
        xml += "<w:name w:val=\"\(style.docxStyleName)\"/>"
        if !isDefault {
            xml += "<w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/>"
            xml += "<w:uiPriority w:val=\"\(style.headingLevel != nil ? 9 : 10)\"/>"
        }
        xml += "<w:qFormat/>"
        if !isDefault {
            xml += "<w:pPr><w:keepNext/><w:keepLines/>"
            xml += "<w:spacing w:before=\"\(DocxWriter.twips(definition.spaceBefore))\" w:after=\"\(DocxWriter.twips(definition.spaceAfter))\"/>"
            if let level = style.headingLevel {
                xml += "<w:outlineLvl w:val=\"\(level - 1)\"/>"
            }
            xml += "</w:pPr>"
            xml += "<w:rPr>"
            if definition.bold { xml += "<w:b/><w:bCs/>" }
            if definition.italic { xml += "<w:i/><w:iCs/>" }
            if definition.colorHex != "000000" { xml += "<w:color w:val=\"\(definition.colorHex)\"/>" }
            xml += "<w:sz w:val=\"\(Int(definition.fontSize * 2))\"/><w:szCs w:val=\"\(Int(definition.fontSize * 2))\"/>"
            xml += "</w:rPr>"
        }
        xml += "</w:style>"
        return xml
    }
}
