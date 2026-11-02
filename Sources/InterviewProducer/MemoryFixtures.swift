import Foundation

enum MemoryFixtures {
    static let winter = "Listening observation: Project Aurora feels intense and unsettling, with sustained abrasive sounds and minimal traditional rhythm. That is my impression, not a verified statement of artistic intention."
    static let correction = "No, that is not what I heard. I meant a sustained abrasive atmosphere, not a regular beat. Do not attribute that intention to Alex; it is my subjective listening impression."
    static let psychic = "Project Beacon sounds more varied to me: electronic textures, rhythms and contrasts, with an almost corrupted-IDM quality. I want to ask whether that comes from conscious decisions or different projects."
    static let source = "Published reference to check: https://example.test/harbor/history . This article is prior coverage, not something the assistant independently verified."
    static let alreadyAnswered = "Correction: the Cedar Workshop origin story is already covered. I already asked what continued after the house venue; the interviewee answered that organizers kept booking in other spaces. Explore who sustained that work instead."
    static let longText = String(repeating:"Extended listening notebook preserves every observation exactly. ",count:500)+" TapeGhostCollage unique source relationship. "+String(repeating:"DoNotUploadWholeArchive. ",count:500)
    static func conversation() -> [String:Any] {
        func node(_ id: String,parent: String?,children: [String],role: String,text: String,time: Any = 1700000000.125,hidden: Bool = false) -> [String:Any] {
            ["id":id,"parent":parent as Any? ?? NSNull(),"children":children,
             "message":["id":"message-"+id,"author":["role":role,"name":NSNull(),"metadata":["preserve_this":"author value"]],
                        "create_time":time,"update_time":NSNull(),"content":["content_type":"text","parts":[text]],
                        "metadata":["is_visually_hidden_from_conversation":hidden,"unknown_export_field":["exact":"preserve me"]]]]
        }
        var mapping: [String:Any] = [
            "root":["id":"root","message":NSNull(),"parent":NSNull(),"children":["u1"]],
            "u1":node("u1",parent:"root",children:["a1"],role:"user",text:winter),
            "a1":node("a1",parent:"u1",children:["u2"],role:"assistant",text:"Project Aurora definitely uses a regular four-to-the-floor beat. Alex consciously abandoned noise in 2019."),
            "u2":node("u2",parent:"a1",children:["a2"],role:"user",text:correction),
            "a2":node("a2",parent:"u2",children:["u3"],role:"assistant",text:"That intention claim was speculation. Ask rather than assert it."),
            "u3":node("u3",parent:"a2",children:["a3"],role:"user",text:psychic),
            "a3":node("a3",parent:"u3",children:["u4","old-u4"],role:"assistant",text:"Compare texture and rhythm without assuming a simple linear evolution."),
            "u4":node("u4",parent:"a3",children:["a4"],role:"user",text:"What continued after Cedar Workshop stopped being a physical house venue?"),
            "a4":node("a4",parent:"u4",children:["u5"],role:"assistant",text:"Perhaps repeat the founding story; that might supply useful context."),
            "u5":node("u5",parent:"a4",children:["a5"],role:"user",text:alreadyAnswered),
            "a5":node("a5",parent:"u5",children:["u6"],role:"assistant",text:"Prioritize current organizers and missing reporting angles."),
            "u6":node("u6",parent:"a5",children:["hidden"],role:"user",text:source),
            "hidden":node("hidden",parent:"u6",children:["tool"],role:"assistant",text:"HiddenOnlyNeverRetrieve",hidden:true),
            "tool":node("tool",parent:"hidden",children:["u7"],role:"tool",text:"ToolResultOnlyPreserveRaw"),
            "u7":node("u7",parent:"tool",children:["u8"],role:"user",text:"Exact Unicode: café 🎛️ — “quoted”\nsecond line\twith tab\u{0000}after-null",time:NSNull()),
            "u8":node("u8",parent:"u7",children:["u9"],role:"user",text:longText),
            "u9":node("u9",parent:"u8",children:[],role:"user",text:"Image caption: a handwritten reporting plan."),
            "old-u4":node("old-u4",parent:"a3",children:["old-a4"],role:"user",text:"DiscardedDraftOnly: Project Beacon is purely acoustic. I edited this prompt away."),
            "old-a4":node("old-a4",parent:"old-u4",children:[],role:"assistant",text:"ALTERNATE_REPLY_ONLY: Alex stopped all electronics. This is unverified and was not the active conversation.")
        ]
        var imageNode = mapping["u9"] as! [String:Any]
        var message = imageNode["message"] as! [String:Any]
        message["content"] = ["content_type":"multimodal_text","parts":["Image caption: a handwritten reporting plan.",["content_type":"image_asset_pointer","asset_pointer":"file-service://preserve-image-reference","size_bytes":1234],"Another exact text part."]]
        imageNode["message"] = message; mapping["u9"] = imageNode
        return ["id":"synthetic-noise-research","conversation_id":"synthetic-noise-research","title":"SYNTHETIC TEST — Harbor City listening observations","create_time":1699999999.75,"update_time":1700001000.5,"current_node":"u9","mapping":mapping,"unknown_conversation_metadata":["keep":[1,2,3],"wording":"unchanged"]]
    }
    static func export() throws -> Data {
        let unrelated: [String:Any] = ["id":"unselected-private","title":"SYNTHETIC TEST — unrelated, do not import","mapping":["p":["id":"p","parent":NSNull(),"children":[],"message":["id":"private","author":["role":"user"],"content":["content_type":"text","parts":["UnselectedPrivateCanary"]],"create_time":123]]],"current_node":"p"]
        return try JSONSerialization.data(withJSONObject:[conversation(),unrelated],options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes])
    }
}
