import Foundation

enum SimulationFixtures {
    static let revelation = [
        InterviewLine(start:10,end:16,speaker:.them,text:"There was a point when we nearly stopped organizing shows altogether."),
        InterviewLine(start:17,end:22,speaker:.me,text:"Interesting. So how has the music changed?")
    ]
    static let revelationDecision = EditorialDecision(should_suggest:true,confidence:0.96,priority:"high",suggested_question:"What nearly made you stop organizing shows?",reason:"A potentially consequential turning point was left unexplained when the subject changed.",evidence_excerpt:"There was a point when we nearly stopped organizing shows altogether.",related_topic:"nearly stopped organizing",timestamp:10)
    struct Scenario {
        var name: String; var lines: [InterviewLine]; var expectAlert: Bool
    }
    static let scenarios: [Scenario] = [
        .init(name:"1 — Major revelation",lines:revelation,expectAlert:true),
        .init(name:"2 — Published origin story",lines:[.init(start:10,end:19,speaker:.them,text:"I started Cedar Workshop in my living room and we hosted more than fifty shows between 2005 and 2010.")],expectAlert:false),
        .init(name:"3 — Unexplained source",lines:[.init(start:10,end:17,speaker:.them,text:"A person named Morgan was essential to keeping the scene alive."),.init(start:18,end:21,speaker:.me,text:"Let's move on to recording.")],expectAlert:true),
        .init(name:"4 — Interviewer follows up",lines:[revelation[0],.init(start:17,end:21,speaker:.me,text:"What nearly made you stop organizing shows?"),.init(start:22,end:28,speaker:.them,text:"We lost our space, then found a new room through friends and kept going.")],expectAlert:false),
        .init(name:"5 — Source discrepancy",lines:[.init(start:10,end:17,speaker:.them,text:"Cedar Collective Records started in 2015, not before that."),.init(start:18,end:20,speaker:.me,text:"What about the latest releases?")],expectAlert:true),
        .init(name:"6 — Small talk",lines:[.init(start:10,end:15,speaker:.them,text:"I had toast for breakfast. The weather is pleasant today.")],expectAlert:false),
        .init(name:"7 — Unreliable transcript",lines:[.init(start:10,end:15,speaker:.them,text:"[unclear] nearly ??? 2019 maybe [unclear]")],expectAlert:false)
    ]
}
