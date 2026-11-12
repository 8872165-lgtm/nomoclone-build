//
//  Presets.swift
//  NomoClone
//
//  The 21 shipped looks, transcribed from Filters/filters.json of NomoRaw 3.0.13.
//

import Foundation

struct Preset: Identifiable, Hashable {
    let id: String          // short key, matches filters.json "name"
    let name: String        // filters.json "des"
    let group: Group
    let lut: String         // cube stem inside Resources/luts, "" = no look
    let exposure: Float     // EV stops, before the 0.65 shader gain
    let vignette: Float     // filters.json "darkCorner" -> multiply-blend strength
    let grain: Float        // filters.json "grains"     -> soft-light strength
    let isBW: Bool

    enum Group: String, CaseIterable { case digital = "Digital", analog = "Analog" }

    var displayName: String { name }
}

enum Presets {
    static let all: [Preset] = [
        .init(id: "/",  name: "NOMO RAW",             group: .digital, lut: "",              exposure: +0.33, vignette: 0.0, grain: 0.0, isBW: false),
        .init(id: "L",  name: "M10 LC",               group: .digital, lut: "NOMORAW-L",     exposure: -0.33, vignette: 0.2, grain: 0.0, isBW: false),
        .init(id: "M",  name: "M10 Standard",         group: .digital, lut: "NOMORAW-M",     exposure: -0.33, vignette: 0.2, grain: 0.0, isBW: false),
        .init(id: "E",  name: "M Monochrom",          group: .digital, lut: "NOMORAW-E",     exposure: -0.33, vignette: 0.2, grain: 0.0, isBW: true),
        .init(id: "X",  name: "907X",                 group: .digital, lut: "NOMORAW-X",     exposure:  0.00, vignette: 0.2, grain: 0.0, isBW: false),
        .init(id: "R",  name: "R5 Auto",              group: .digital, lut: "NOMORAW-R",     exposure:  0.00, vignette: 0.0, grain: 0.0, isBW: false),
        .init(id: "A",  name: "α7 Standard",          group: .digital, lut: "NOMORAW-A",     exposure:  0.00, vignette: 0.0, grain: 0.0, isBW: false),
        .init(id: "P",  name: "X100V Provia",         group: .digital, lut: "NOMORAW-P",     exposure:  0.00, vignette: 0.0, grain: 0.0, isBW: false),
        .init(id: "C",  name: "X100V C-Chrome",       group: .digital, lut: "NOMORAW-C",     exposure:  0.00, vignette: 0.0, grain: 0.0, isBW: false),
        .init(id: "B",  name: "X100V Acros",          group: .digital, lut: "NOMORAW-B",     exposure:  0.00, vignette: 0.0, grain: 0.0, isBW: true),
        .init(id: "G",  name: "GR III Hi-BW",         group: .digital, lut: "NOMORAW-G",     exposure:  0.00, vignette: 0.2, grain: 0.8, isBW: true),
        .init(id: "H",  name: "GR III Hard-BW",       group: .digital, lut: "NOMORAW-H-020", exposure:  0.00, vignette: 0.3, grain: 1.0, isBW: true),
        .init(id: "f1", name: "Fujicolor Pro 160C",   group: .analog,  lut: "NOMORAW-f1",    exposure: +0.33, vignette: 0.3, grain: 0.5, isBW: false),
        .init(id: "f3", name: "F-CP TYPE3510",        group: .analog,  lut: "NOMORAW-f3",    exposure: +0.33, vignette: 0.3, grain: 0.5, isBW: false),
        .init(id: "f4", name: "Fujicolor Superia 400",group: .analog,  lut: "NOMORAW-f4",    exposure: +0.33, vignette: 0.3, grain: 0.5, isBW: false),
        .init(id: "k1", name: "Kodak Portra 160",     group: .analog,  lut: "NOMORAW-k1",    exposure: +0.33, vignette: 0.3, grain: 0.5, isBW: false),
        .init(id: "k2", name: "KODAK VISION 2383",    group: .analog,  lut: "NOMORAW-k2",    exposure: +0.33, vignette: 0.3, grain: 0.5, isBW: false),
        .init(id: "k4", name: "Kodak Portra 400",     group: .analog,  lut: "NOMORAW-k4",    exposure: +0.33, vignette: 0.3, grain: 0.5, isBW: false),
        .init(id: "a1", name: "Agfa Portrait 160",    group: .analog,  lut: "NOMORAW-a1",    exposure: +0.33, vignette: 0.3, grain: 0.5, isBW: false),
        .init(id: "a4", name: "AgfaPhoto Vista 400",  group: .analog,  lut: "NOMORAW-a4",    exposure: +0.33, vignette: 0.3, grain: 0.5, isBW: false),
        .init(id: "x4", name: "Kodak Tri-X 400",      group: .analog,  lut: "NOMORAW-x4",    exposure: +0.33, vignette: 0.3, grain: 0.5, isBW: true),
    ]

    static func preset(id: String) -> Preset? { all.first { $0.id == id } }
    static var grouped: [(Preset.Group, [Preset])] {
        Preset.Group.allCases.map { g in (g, all.filter { $0.group == g }) }
    }
}
