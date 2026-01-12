pub const EncodingError = error{
    BufferTooSmall,
    ValueTooLarge,
    InvalidParameters,
};

pub const DecodingError = error{
    EmptyBuffer,
    InsufficientData,
    InvalidFormat,
    ValueOutOfRange,
};

pub const ScannerError = error{
    BufferOverrun,
    InvalidCursor,
};

pub const BlobDictError = error{
    KeysNotSorted,
    DuplicateKey,
    KeyNotFound,
};

pub const CodecError = EncodingError || DecodingError || ScannerError || BlobDictError;
