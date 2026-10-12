import json,sys
d=json.load(open(sys.argv[1]))
fx=d['fixed']
L=["//! Mapping between `dnp3::app::Variation` and (group, variation) pairs.",
"//!","//! Generated from dnp3 1.7.0 `app/variations.rs` by `tool/gen_variations.py`. Do not edit.","",
"use dnp3::app::Variation;","",
"pub fn to_group_var(v: Variation) -> (u8, u8) {","    match v {",
"        Variation::Group0(x) => (0, x),","        Variation::Group110(x) => (110, x),","        Variation::Group111(x) => (111, x),"]
for n,g,v,_ in fx:
    L.append(f"        Variation::{n} => ({g}, {v}),")
L+=["    }","}","","pub fn from_group_var(group: u8, var: u8) -> Option<Variation> {","    let v = match (group, var) {"]
for n,g,v,_ in fx:
    L.append(f"        ({g}, {v}) => Variation::{n},")
L+=["        (0, x) => Variation::Group0(x),","        (110, x) => Variation::Group110(x),","        (111, x) => Variation::Group111(x),","        _ => return None,","    };","    Some(v)","}",""]
open(sys.argv[2],'w').write("\n".join(L))
