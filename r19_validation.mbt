///|
/// Validate the canonical R19-11 header/payload interpretation without changing
/// byte-preserving decode(). A capture may still be readable after a violation.
pub fn Message::validate_r19(
  self : Message,
  limits~ : Limits = Limits::default(),
  budget~ : TreeBudget = TreeBudget::default(),
) -> Unit raise DltError {
  check_limits(limits)
  let scratch = @buffer.Buffer::Buffer()
  write_header(scratch, self.header, self.payload.length(), limits)
  if self.storage is Some(s) {
    ignore(s.time_microseconds())
    scratch.reset()
    write_id(scratch, s.ecu)
  }
  guard self.header.extended is Some(e) else {
    if self.payload.length() != 0 {
      ignore(self.nonverbose_id())
    }
    return
  }
  if !e.verbose {
    guard e.argument_count == 0 else {
      raise Invalid(0, "R19-11 nonverbose NOAR must be zero")
    }
  }
  match e.message_type {
    0 => {
      guard e.subtype >= 1 && e.subtype <= 6 else {
        raise Unsupported(0, "reserved log message subtype")
      }
    }
    1 => {
      guard e.subtype >= 1 && e.subtype <= 5 else {
        raise Unsupported(0, "reserved application trace subtype")
      }
    }
    2 => {
      guard e.subtype >= 1 && e.subtype <= 15 else {
        raise Unsupported(0, "reserved network trace subtype")
      }
    }
    3 => {
      match e.subtype {
        1 => ignore(self.standard_control_request())
        2 => ignore(self.standard_control_response())
        _ => raise Unsupported(0, "reserved control message subtype")
      }
      return
    }
    _ => raise Unsupported(0, "reserved message type")
  }
  if e.verbose {
    ignore(self.wire_parameters(limits~, budget~))
  } else {
    ignore(self.nonverbose_id())
  }
}

///|
/// Attach reception metadata provided by the capture host to a DLT record.
pub fn Message::with_reception(
  self : Message,
  seconds~ : UInt32,
  microseconds~ : UInt32,
  ecu~ : String,
  limits~ : Limits = Limits::default(),
) -> Message raise DltError {
  check_limits(limits)
  let storage : StorageHeader = { seconds, microseconds, ecu, }
  finish_verbose_message(self.header, self.payload, Some(storage), limits)
}
