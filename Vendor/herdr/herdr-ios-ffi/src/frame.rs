//! Buffered frame reading: complete frames decode, truncated tails wait,
//! violations fail the client.
use herdr_protocol::{read_message, FramingError};
use std::io::Read;

pub(crate) enum FrameRead {
    Partial,
    Invalid(FramingError),
}

pub(crate) fn read_frame<R: Read, M: for<'de> serde::Deserialize<'de>>(
    reader: &mut R,
    max_frame_size: usize,
) -> Result<M, FrameRead> {
    match read_message(reader, max_frame_size) {
        Ok(message) => Ok(message),
        Err(FramingError::UnexpectedEof) => {
            // A truncated buffer tail is a partial frame: keep it buffered.
            Err(FrameRead::Partial)
        }
        Err(other) => Err(FrameRead::Invalid(other)),
    }
}
