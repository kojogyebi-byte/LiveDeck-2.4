import Foundation

/// Canonical 66-book Protestant canon with USFM codes and common English abbreviations.
/// Imported translations may add their own (non-English) book names, which the reference
/// parser also matches.
public struct BibleBookInfo: Hashable, Sendable {
    public let number: Int      // 1…66
    public let code: String     // USFM code (GEN, 1CO, JHN…)
    public let name: String
    public let aliases: [String]
    public let chapters: Int

    public static let all: [BibleBookInfo] = [
        BibleBookInfo(number: 1, code: "GEN", name: "Genesis", aliases: ["Gen", "Ge", "Gn"], chapters: 50),
        BibleBookInfo(number: 2, code: "EXO", name: "Exodus", aliases: ["Exod", "Exo", "Ex"], chapters: 40),
        BibleBookInfo(number: 3, code: "LEV", name: "Leviticus", aliases: ["Lev", "Le", "Lv"], chapters: 27),
        BibleBookInfo(number: 4, code: "NUM", name: "Numbers", aliases: ["Num", "Nu", "Nm", "Nb"], chapters: 36),
        BibleBookInfo(number: 5, code: "DEU", name: "Deuteronomy", aliases: ["Deut", "Deu", "Dt"], chapters: 34),
        BibleBookInfo(number: 6, code: "JOS", name: "Joshua", aliases: ["Josh", "Jos", "Jsh"], chapters: 24),
        BibleBookInfo(number: 7, code: "JDG", name: "Judges", aliases: ["Judg", "Jdg", "Jg", "Jdgs"], chapters: 21),
        BibleBookInfo(number: 8, code: "RUT", name: "Ruth", aliases: ["Rth", "Ru"], chapters: 4),
        BibleBookInfo(number: 9, code: "1SA", name: "1 Samuel", aliases: ["1 Sam", "1Sam", "1 Sa", "1Sa", "1S", "I Samuel", "First Samuel"], chapters: 31),
        BibleBookInfo(number: 10, code: "2SA", name: "2 Samuel", aliases: ["2 Sam", "2Sam", "2 Sa", "2Sa", "2S", "II Samuel", "Second Samuel"], chapters: 24),
        BibleBookInfo(number: 11, code: "1KI", name: "1 Kings", aliases: ["1 Kgs", "1Kgs", "1 Ki", "1Ki", "1K", "I Kings", "First Kings"], chapters: 22),
        BibleBookInfo(number: 12, code: "2KI", name: "2 Kings", aliases: ["2 Kgs", "2Kgs", "2 Ki", "2Ki", "2K", "II Kings", "Second Kings"], chapters: 25),
        BibleBookInfo(number: 13, code: "1CH", name: "1 Chronicles", aliases: ["1 Chron", "1Chron", "1 Chr", "1Chr", "1 Ch", "1Ch", "I Chronicles", "First Chronicles"], chapters: 29),
        BibleBookInfo(number: 14, code: "2CH", name: "2 Chronicles", aliases: ["2 Chron", "2Chron", "2 Chr", "2Chr", "2 Ch", "2Ch", "II Chronicles", "Second Chronicles"], chapters: 36),
        BibleBookInfo(number: 15, code: "EZR", name: "Ezra", aliases: ["Ezr", "Ez"], chapters: 10),
        BibleBookInfo(number: 16, code: "NEH", name: "Nehemiah", aliases: ["Neh", "Ne"], chapters: 13),
        BibleBookInfo(number: 17, code: "EST", name: "Esther", aliases: ["Esth", "Est", "Es"], chapters: 10),
        BibleBookInfo(number: 18, code: "JOB", name: "Job", aliases: ["Jb"], chapters: 42),
        BibleBookInfo(number: 19, code: "PSA", name: "Psalms", aliases: ["Psalm", "Ps", "Psa", "Pss", "Psm"], chapters: 150),
        BibleBookInfo(number: 20, code: "PRO", name: "Proverbs", aliases: ["Prov", "Pro", "Prv", "Pr"], chapters: 31),
        BibleBookInfo(number: 21, code: "ECC", name: "Ecclesiastes", aliases: ["Eccles", "Eccl", "Ecc", "Ec", "Qoh"], chapters: 12),
        BibleBookInfo(number: 22, code: "SNG", name: "Song of Solomon", aliases: ["Song of Songs", "Song", "Songs", "SOS", "So", "Canticles", "Cant"], chapters: 8),
        BibleBookInfo(number: 23, code: "ISA", name: "Isaiah", aliases: ["Isa", "Is"], chapters: 66),
        BibleBookInfo(number: 24, code: "JER", name: "Jeremiah", aliases: ["Jer", "Je", "Jr"], chapters: 52),
        BibleBookInfo(number: 25, code: "LAM", name: "Lamentations", aliases: ["Lam", "La"], chapters: 5),
        BibleBookInfo(number: 26, code: "EZK", name: "Ezekiel", aliases: ["Ezek", "Eze", "Ezk"], chapters: 48),
        BibleBookInfo(number: 27, code: "DAN", name: "Daniel", aliases: ["Dan", "Da", "Dn"], chapters: 12),
        BibleBookInfo(number: 28, code: "HOS", name: "Hosea", aliases: ["Hos", "Ho"], chapters: 14),
        BibleBookInfo(number: 29, code: "JOL", name: "Joel", aliases: ["Joe", "Jl"], chapters: 3),
        BibleBookInfo(number: 30, code: "AMO", name: "Amos", aliases: ["Amo", "Am"], chapters: 9),
        BibleBookInfo(number: 31, code: "OBA", name: "Obadiah", aliases: ["Obad", "Ob"], chapters: 1),
        BibleBookInfo(number: 32, code: "JON", name: "Jonah", aliases: ["Jnh", "Jon"], chapters: 4),
        BibleBookInfo(number: 33, code: "MIC", name: "Micah", aliases: ["Mic", "Mc"], chapters: 7),
        BibleBookInfo(number: 34, code: "NAM", name: "Nahum", aliases: ["Nah", "Na"], chapters: 3),
        BibleBookInfo(number: 35, code: "HAB", name: "Habakkuk", aliases: ["Hab", "Hb"], chapters: 3),
        BibleBookInfo(number: 36, code: "ZEP", name: "Zephaniah", aliases: ["Zeph", "Zep", "Zp"], chapters: 3),
        BibleBookInfo(number: 37, code: "HAG", name: "Haggai", aliases: ["Hag", "Hg"], chapters: 2),
        BibleBookInfo(number: 38, code: "ZEC", name: "Zechariah", aliases: ["Zech", "Zec", "Zc"], chapters: 14),
        BibleBookInfo(number: 39, code: "MAL", name: "Malachi", aliases: ["Mal", "Ml"], chapters: 4),
        BibleBookInfo(number: 40, code: "MAT", name: "Matthew", aliases: ["Matt", "Mat", "Mt"], chapters: 28),
        BibleBookInfo(number: 41, code: "MRK", name: "Mark", aliases: ["Mrk", "Mar", "Mk", "Mr"], chapters: 16),
        BibleBookInfo(number: 42, code: "LUK", name: "Luke", aliases: ["Luk", "Lk"], chapters: 24),
        BibleBookInfo(number: 43, code: "JHN", name: "John", aliases: ["Jhn", "Joh", "Jn"], chapters: 21),
        BibleBookInfo(number: 44, code: "ACT", name: "Acts", aliases: ["Act", "Ac"], chapters: 28),
        BibleBookInfo(number: 45, code: "ROM", name: "Romans", aliases: ["Rom", "Ro", "Rm"], chapters: 16),
        BibleBookInfo(number: 46, code: "1CO", name: "1 Corinthians", aliases: ["1 Cor", "1Cor", "1 Co", "1Co", "I Corinthians", "First Corinthians"], chapters: 16),
        BibleBookInfo(number: 47, code: "2CO", name: "2 Corinthians", aliases: ["2 Cor", "2Cor", "2 Co", "2Co", "II Corinthians", "Second Corinthians"], chapters: 13),
        BibleBookInfo(number: 48, code: "GAL", name: "Galatians", aliases: ["Gal", "Ga"], chapters: 6),
        BibleBookInfo(number: 49, code: "EPH", name: "Ephesians", aliases: ["Eph", "Ephes"], chapters: 6),
        BibleBookInfo(number: 50, code: "PHP", name: "Philippians", aliases: ["Phil", "Php", "Pp"], chapters: 4),
        BibleBookInfo(number: 51, code: "COL", name: "Colossians", aliases: ["Col", "Co"], chapters: 4),
        BibleBookInfo(number: 52, code: "1TH", name: "1 Thessalonians", aliases: ["1 Thess", "1Thess", "1 Thes", "1Thes", "1 Th", "1Th", "I Thessalonians", "First Thessalonians"], chapters: 5),
        BibleBookInfo(number: 53, code: "2TH", name: "2 Thessalonians", aliases: ["2 Thess", "2Thess", "2 Thes", "2Thes", "2 Th", "2Th", "II Thessalonians", "Second Thessalonians"], chapters: 3),
        BibleBookInfo(number: 54, code: "1TI", name: "1 Timothy", aliases: ["1 Tim", "1Tim", "1 Ti", "1Ti", "I Timothy", "First Timothy"], chapters: 6),
        BibleBookInfo(number: 55, code: "2TI", name: "2 Timothy", aliases: ["2 Tim", "2Tim", "2 Ti", "2Ti", "II Timothy", "Second Timothy"], chapters: 4),
        BibleBookInfo(number: 56, code: "TIT", name: "Titus", aliases: ["Tit", "Ti"], chapters: 3),
        BibleBookInfo(number: 57, code: "PHM", name: "Philemon", aliases: ["Philem", "Phm", "Pm"], chapters: 1),
        BibleBookInfo(number: 58, code: "HEB", name: "Hebrews", aliases: ["Heb"], chapters: 13),
        BibleBookInfo(number: 59, code: "JAS", name: "James", aliases: ["Jas", "Jm"], chapters: 5),
        BibleBookInfo(number: 60, code: "1PE", name: "1 Peter", aliases: ["1 Pet", "1Pet", "1 Pe", "1Pe", "1 Pt", "1Pt", "I Peter", "First Peter"], chapters: 5),
        BibleBookInfo(number: 61, code: "2PE", name: "2 Peter", aliases: ["2 Pet", "2Pet", "2 Pe", "2Pe", "2 Pt", "2Pt", "II Peter", "Second Peter"], chapters: 3),
        BibleBookInfo(number: 62, code: "1JN", name: "1 John", aliases: ["1 Jn", "1Jn", "1 Jhn", "1Jhn", "1 Jo", "1Jo", "I John", "First John"], chapters: 5),
        BibleBookInfo(number: 63, code: "2JN", name: "2 John", aliases: ["2 Jn", "2Jn", "2 Jhn", "2Jhn", "2 Jo", "2Jo", "II John", "Second John"], chapters: 1),
        BibleBookInfo(number: 64, code: "3JN", name: "3 John", aliases: ["3 Jn", "3Jn", "3 Jhn", "3Jhn", "3 Jo", "3Jo", "III John", "Third John"], chapters: 1),
        BibleBookInfo(number: 65, code: "JUD", name: "Jude", aliases: ["Jud", "Jd"], chapters: 1),
        BibleBookInfo(number: 66, code: "REV", name: "Revelation", aliases: ["Rev", "Re", "Rv", "Revelations", "Apocalypse"], chapters: 22),
    ]

    public static func byCode(_ code: String) -> BibleBookInfo? {
        let c = code.uppercased()
        return all.first { $0.code == c } ?? codeAliases[c].flatMap { a in all.first { $0.code == a } }
    }
    public static func byNumber(_ n: Int) -> BibleBookInfo? { (1...66).contains(n) ? all[n - 1] : nil }

    /// OSIS / Zefania / other code spellings → USFM.
    static let codeAliases: [String: String] = [
        "GENESIS": "GEN", "EXOD": "EXO", "LEV": "LEV", "NUM": "NUM", "DEUT": "DEU", "JOSH": "JOS", "JUDG": "JDG", "RUTH": "RUT",
        "1SAM": "1SA", "2SAM": "2SA", "1KGS": "1KI", "2KGS": "2KI", "1CHR": "1CH", "2CHR": "2CH", "NEH": "NEH", "ESTH": "EST",
        "PS": "PSA", "PSS": "PSA", "PROV": "PRO", "ECCL": "ECC", "SONG": "SNG", "SOS": "SNG", "ISA": "ISA", "JER": "JER",
        "LAM": "LAM", "EZEK": "EZK", "EZE": "EZK", "DAN": "DAN", "HOS": "HOS", "JOEL": "JOL", "AMOS": "AMO", "OBAD": "OBA",
        "JONAH": "JON", "MIC": "MIC", "NAH": "NAM", "HAB": "HAB", "ZEPH": "ZEP", "HAG": "HAG", "ZECH": "ZEC", "MAL": "MAL",
        "MATT": "MAT", "MARK": "MRK", "MAR": "MRK", "LUKE": "LUK", "JOHN": "JHN", "JOH": "JHN", "ACTS": "ACT", "ROM": "ROM",
        "EZRA": "EZR", "1COR": "1CO", "2COR": "2CO", "GAL": "GAL", "EPH": "EPH", "PHIL": "PHP", "COL": "COL", "1THESS": "1TH", "2THESS": "2TH",
        "1TIM": "1TI", "2TIM": "2TI", "TITUS": "TIT", "PHLM": "PHM", "HEB": "HEB", "JAS": "JAS", "1PET": "1PE", "2PET": "2PE",
        "1JOHN": "1JN", "2JOHN": "2JN", "3JOHN": "3JN", "JUDE": "JUD", "REV": "REV"
    ]
}
