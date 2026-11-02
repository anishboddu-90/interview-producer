import Foundation

enum LifelineFixtures {
    static var profile: QuestionProfile {
        .init(id:"synthetic-question-profile",name:"Synthetic music interview",source:"Synthetic Source Alder",questions:[
            .init(id:"origins",text:"What first brought you to the local community?",category:"Background",priority:2),
            .init(id:"music",text:"Which two recordings demonstrate the electronic textures you hear, and what should we listen for?",category:"Musical development",priority:4,essential:true),
            .init(id:"networks",text:"Which touring relationships connect your community to artists outside Texas?",category:"National networks",priority:4,essential:true),
            .init(id:"people",text:"Who contributed something important that the existing histories have overlooked?",category:"Cultural history",priority:3)
        ])
    }
    static func record(_ text: String = "The electronic textures have changed, but I have not yet named any recordings to compare.") -> InterviewRecord {
        var r = StoryFixtures.interview(); r.questionProfileID = profile.id
        r.lines = [.init(start:10,end:20,speaker:.them,text:text)]; return r
    }
    static func review(_ record: InterviewRecord,id: String? = "music") -> LifelineReview {
        .init(next_question_id:id,bridge:"",reason:"A concrete comparison would test the listening claim.",confidence:0.99,
              answer_complete:true,thinking_pause:false,pending_followup:false,anchor_ref:StoryEvidence.passages([record]).last?.id,answers:[],source_refs:[])
    }
    static let substantive = "For the earlier recording, compare the first minute of the fictional Tape Cedar with the last two minutes of the fictional Tape Elm. Listen for the pulsing delay and the thinner layers of electronics; I am only describing those two recordings."
}
