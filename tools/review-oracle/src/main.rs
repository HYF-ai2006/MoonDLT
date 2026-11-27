//! Independent reader/writer for the common LE vectors. Only the DLT structure
//! prefix is supplied by the harness because StructValue has no public builder.
use arrayvec::ArrayVec;
use dlt_parse::verbose::{F128Value, F16Value, I128Value, RawF128, RawF16, Scaling,
                        TraceInfoValue, U128Value, VerboseValue};
use std::{env, fs};

const COUNTER: u128 = (1 << 96) + 1;
const BINARY128: u128 = (0x3fff_u128 << 112) + 1;

fn main() {
    let args: Vec<_> = env::args().skip(1).collect();
    match args[0].as_str() {
        "emit" => {
            let mut b = ArrayVec::<u8, 256>::new();
            b.try_extend_from_slice(&[0, 0x40, 0, 0, 2, 0]).unwrap();
            TraceInfoValue { value: "boot" }.add_to_msg(&mut b, false).unwrap();
            U128Value { variable_info: None, scaling: None, value: COUNTER }
                .add_to_msg(&mut b, false).unwrap();
            fs::write(&args[1], &b).unwrap();
        }
        "check" => {
            let b = fs::read(&args[1]).unwrap();
            let (value, rest) = VerboseValue::from_slice(&b, false).unwrap();
            assert!(rest.is_empty());
            let VerboseValue::Struct(s) = value else { panic!("expected struct") };
            assert_eq!(s.number_of_entries, 2);
            let mut iter = s.entries();
            assert!(matches!(iter.next().unwrap().unwrap(), VerboseValue::TraceInfo(v) if v.value == "ready"));
            assert!(matches!(iter.next().unwrap().unwrap(), VerboseValue::U128(v) if v.value == COUNTER));
            assert!(iter.next().is_none());
        }
        "wide" => {
            let mut b = ArrayVec::<u8, 256>::new();
            I128Value { variable_info: None, scaling: Some(Scaling {
                quantization: 0.5, offset: -(1i128 << 96),
            }), value: i128::MIN }.add_to_msg(&mut b, false).unwrap();
            F16Value { variable_info: None, value: RawF16::from_bits(0x8000) }.add_to_msg(&mut b, false).unwrap();
            F128Value { variable_info: None, value: RawF128::from_bits(BINARY128) }.add_to_msg(&mut b, false).unwrap();
            fs::write(&args[1], &b).unwrap();
        }
        "wide-check" => {
            let b = fs::read(&args[1]).unwrap();
            let (i, tail) = VerboseValue::from_slice(&b, false).unwrap();
            let VerboseValue::I128(i) = i else { panic!("expected i128") };
            assert_eq!(i.value, i128::MIN + 1);
            let s = i.scaling.unwrap();
            assert_eq!(s.offset, -(1i128 << 96));
            assert_eq!(s.quantization, 0.5);
            let (f,tail) = VerboseValue::from_slice(tail,false).unwrap();
            assert!(matches!(f,VerboseValue::F16(v) if v.value.to_bits() == 0x8000));
            let (f,tail) = VerboseValue::from_slice(tail,false).unwrap();
            assert!(matches!(f,VerboseValue::F128(v) if v.value.to_bits() == BINARY128));
            assert!(tail.is_empty());
        }
        _ => panic!("unknown oracle operation"),
    }
}
