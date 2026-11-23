///|
/// Read an array element using zero-based C-order coordinates.
/// Scalar parameters accept an empty coordinate list only.
pub fn VerboseParameter::at(
  self : VerboseParameter,
  indices : Array[Int32],
  limits~ : Limits = Limits::default(),
) -> Argument raise DltError {
  check_limits(limits)
  match self.value {
    Scalar(argument) => {
      guard indices.is_empty() else {
        raise Invalid(0, "scalar parameter has no axes")
      }
      ignore(argument_wire_length(argument, limits))
      argument
    }
    NumericArray(kind, dimensions, values) => {
      validate_numeric_array(kind, dimensions, values, limits)
      guard indices.length() == dimensions.length() else {
        raise Invalid(0, "array coordinate rank disagrees with dimensions")
      }
      let mut index = 0
      for axis in 0..<dimensions.length() {
        let coordinate = indices[axis]
        guard coordinate >= 0 && coordinate < dimensions[axis] else {
          raise Invalid(axis, "array coordinate outside axis")
        }
        index = index * dimensions[axis] + coordinate
      }
      values[index]
    }
  }
}

///|
/// Return a rectangular strided section with the same type, VARI and FIXP.
/// Each count is positive, steps are positive, and axes are never transposed.
pub fn VerboseParameter::section(
  self : VerboseParameter,
  starts : Array[Int32],
  counts : Array[Int32],
  steps? : Array[Int32],
  limits~ : Limits = Limits::default(),
) -> VerboseParameter raise DltError {
  check_limits(limits)
  let (kind, dimensions, values) = match self.value {
    NumericArray(kind, dimensions, values) => (kind, dimensions, values)
    _ => raise Invalid(0, "section requires a numeric array parameter")
  }
  validate_numeric_array(kind, dimensions, values, limits)
  let rank = dimensions.length()
  guard starts.length() == rank && counts.length() == rank else {
    raise Invalid(0, "section start/count ranks disagree with the array")
  }
  let actual_steps = match steps {
    Some(value) => value
    None => Array::make(rank, 1)
  }
  guard actual_steps.length() == rank else {
    raise Invalid(0, "section step rank disagrees with the array")
  }
  let length = dimensions_count(counts, numeric_type_width(kind), limits)
  for axis in 0..<rank {
    let start = starts[axis]
    let step = actual_steps[axis]
    guard start >= 0 && start < dimensions[axis] && step > 0 else {
      raise Invalid(axis, "section origin or step is invalid")
    }
    let remaining = dimensions[axis] - 1 - start
    guard counts[axis] - 1 <= remaining / step else {
      raise Invalid(axis, "strided section extends beyond array axis")
    }
  }
  let selected : Array[Argument] = []
  let coordinates = Array::make(rank, 0)
  for _ in 0..<length {
    let mut source_index = 0
    for axis in 0..<rank {
      source_index = source_index * dimensions[axis] +
        starts[axis] +
        coordinates[axis] * actual_steps[axis]
    }
    selected.push(values[source_index])
    let mut axis = rank - 1
    while axis >= 0 {
      coordinates[axis] += 1
      if coordinates[axis] < counts[axis] {
        break
      }
      coordinates[axis] = 0
      axis -= 1
    }
  }
  { ..self, value: NumericArray(kind, counts.copy(), selected), }
}

///|
/// Change dimensions without changing data order or the number of elements.
pub fn VerboseParameter::reshape(
  self : VerboseParameter,
  dimensions : Array[Int32],
  limits~ : Limits = Limits::default(),
) -> VerboseParameter raise DltError {
  check_limits(limits)
  let (kind, old_dimensions, values) = match self.value {
    NumericArray(kind, old_dimensions, values) => (kind, old_dimensions, values)
    _ => raise Invalid(0, "reshape requires a numeric array parameter")
  }
  validate_numeric_array(kind, old_dimensions, values, limits)
  let count = dimensions_count(dimensions, numeric_type_width(kind), limits)
  guard count == values.length() else {
    raise Invalid(0, "reshape must preserve the total number of elements")
  }
  { ..self, value: NumericArray(kind, dimensions.copy(), values.copy()), }
}

///|
fn validate_numeric_array(
  kind : NumericType,
  dimensions : Array[Int32],
  values : Array[Argument],
  limits : Limits,
) -> Unit raise DltError {
  let count = dimensions_count(dimensions, numeric_type_width(kind), limits)
  guard values.length() == count else {
    raise Invalid(0, "array data count disagrees with dimension product")
  }
  for value in values {
    guard argument_matches_numeric(value, kind) else {
      raise Invalid(0, "array element disagrees with descriptor")
    }
    ignore(argument_wire_length(value, limits))
  }
}

///|
/// Extract an exact signed value; unsigned values above Int64::MAX fail.
pub fn Argument::as_int64(self : Argument) -> Int64 raise DltError {
  match self {
    Signed(width, value) => {
      check_signed(width, value)
      value
    }
    Unsigned(width, value) => {
      check_unsigned(width, value)
      guard value <= 0x7FFFFFFFFFFFFFFFUL else {
        raise Invalid(0, "unsigned parameter cannot be represented by Int64")
      }
      value.reinterpret_as_int64()
    }
    _ => raise Invalid(0, "parameter is not an integer")
  }
}

///|
/// Extract an exact unsigned value; negative signed values fail.
pub fn Argument::as_uint64(self : Argument) -> UInt64 raise DltError {
  match self {
    Unsigned(width, value) => {
      check_unsigned(width, value)
      value
    }
    Signed(width, value) => {
      check_signed(width, value)
      guard value >= 0L else {
        raise Invalid(0, "negative parameter cannot be UInt64")
      }
      value.reinterpret_as_uint64()
    }
    _ => raise Invalid(0, "parameter is not an integer")
  }
}

///|
/// Convert for numerical analysis. By default integers outside the portable
/// JavaScript safe-integer interval fail rather than silently losing precision.
pub fn Argument::as_double(
  self : Argument,
  allow_lossy~ : Bool = false,
) -> Double raise DltError {
  match self {
    Signed(width, value) => {
      check_signed(width, value)
      guard allow_lossy ||
        (value >= -9007199254740991L && value <= 9007199254740991L) else {
        raise Invalid(0, "integer exceeds the safe Double conversion interval")
      }
      value.to_double()
    }
    Unsigned(width, value) => {
      check_unsigned(width, value)
      guard allow_lossy || value <= 9007199254740991UL else {
        raise Invalid(0, "integer exceeds the safe Double conversion interval")
      }
      value.to_double()
    }
    Floating(width, value) => {
      guard width == 32 || width == 64 else {
        raise Unsupported(0, "unsupported floating width")
      }
      if width == 32 {
        Float::from_double(value).to_double()
      } else {
        value
      }
    }
    _ => raise Invalid(0, "parameter is not numeric")
  }
}

///|
pub fn Argument::as_bool(self : Argument) -> Bool raise DltError {
  match self {
    Boolean(value) => value
    _ => raise Invalid(0, "parameter is not Boolean")
  }
}

///|
pub fn Argument::as_text(self : Argument) -> String raise DltError {
  match self {
    Text(_, value) => value
    _ => raise Invalid(0, "parameter is not text")
  }
}

///|
pub fn Argument::as_raw(self : Argument) -> Bytes raise DltError {
  match self {
    Raw(value) => value
    _ => raise Invalid(0, "parameter is not raw data")
  }
}
