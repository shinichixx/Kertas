import Foundation

/// Converts common American spellings to British ones, keeping capitalisation.
enum BritishSpelling {
    private static let words: [String: String] = [
        "color": "colour", "colors": "colours", "colored": "coloured", "colorful": "colourful",
        "honor": "honour", "honors": "honours", "honored": "honoured", "honorable": "honourable",
        "favor": "favour", "favors": "favours", "favorable": "favourable", "favorite": "favourite", "favorites": "favourites",
        "labor": "labour", "neighbor": "neighbour", "neighbors": "neighbours", "neighborhood": "neighbourhood",
        "behavior": "behaviour", "behaviors": "behaviours", "flavor": "flavour", "humor": "humour", "rumor": "rumour",
        "harbor": "harbour", "endeavor": "endeavour", "savior": "saviour", "vapor": "vapour", "armor": "armour",
        "center": "centre", "centers": "centres", "centered": "centred", "theater": "theatre", "fiber": "fibre",
        "liter": "litre", "liters": "litres", "kilometer": "kilometre", "kilometers": "kilometres",
        "centimeter": "centimetre", "millimeter": "millimetre",
        "defense": "defence", "offense": "offence", "pretense": "pretence",
        "catalog": "catalogue", "dialog": "dialogue", "analog": "analogue",
        "gray": "grey", "jewelry": "jewellery", "aluminum": "aluminium", "pajamas": "pyjamas",
        "traveled": "travelled", "traveling": "travelling", "traveler": "traveller", "travelers": "travellers",
        "canceled": "cancelled", "canceling": "cancelling", "labeled": "labelled", "labeling": "labelling",
        "modeling": "modelling", "modeled": "modelled", "fueled": "fuelled", "fueling": "fuelling",
        "enrollment": "enrolment", "fulfill": "fulfil", "fulfillment": "fulfilment", "enroll": "enrol", "skillful": "skilful",
        "analyze": "analyse", "analyzed": "analysed", "analyzing": "analysing", "paralyze": "paralyse",
        "mold": "mould", "plow": "plough", "tire": "tyre", "tires": "tyres", "curb": "kerb",
    ]

    /// -ize words that must stay as they are.
    private static let keepIze: Set<String> = ["size", "sizes", "sized", "seize", "seized", "prize", "prizes", "capsize", "baize", "maize"]

    static func convert(_ text: String) -> String {
        var out = ""
        var word = ""
        func flush() {
            if !word.isEmpty { out += british(word); word = "" }
        }
        for ch in text {
            if ch.isLetter { word.append(ch) } else { flush(); out.append(ch) }
        }
        flush()
        return out
    }

    private static func british(_ w: String) -> String {
        let low = w.lowercased()
        var result: String?
        if let mapped = words[low] {
            result = mapped
        } else if !keepIze.contains(low) {
            for (us, uk) in [("ization", "isation"), ("izations", "isations"), ("izing", "ising"), ("ized", "ised"), ("izes", "ises"), ("ize", "ise"), ("izer", "iser")]
            where low.hasSuffix(us) && low.count > us.count + 2 {
                result = String(low.dropLast(us.count)) + uk
                break
            }
        }
        guard let r = result else { return w }
        if w == w.uppercased() { return r.uppercased() }
        if w.first?.isUppercase == true { return r.prefix(1).uppercased() + r.dropFirst() }
        return r
    }
}
