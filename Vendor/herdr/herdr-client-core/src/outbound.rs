// Adapted queue accounting from upstream endpoint/writer.rs; the caller writes drained frames.
use crate::protocol::{write_message, ClientMessage};
use crate::EndpointTransport;
use std::collections::VecDeque;
use std::io;
use std::sync::{Arc, Mutex, MutexGuard};

#[derive(Clone, Copy)]
pub struct QueueLimits {
    pub messages: usize,
    pub bytes: usize,
}

struct Queue {
    frames: VecDeque<Vec<u8>>,
    bytes: usize,
    closed: bool,
    limits: QueueLimits,
}

#[derive(Clone)]
pub struct OutboundQueue(Arc<Mutex<Queue>>);

impl OutboundQueue {
    pub fn new(limits: QueueLimits) -> Self {
        Self(Arc::new(Mutex::new(Queue {
            frames: VecDeque::new(),
            bytes: 0,
            closed: false,
            limits,
        })))
    }

    fn lock(&self) -> io::Result<MutexGuard<'_, Queue>> {
        self.0
            .lock()
            .map_err(|_| io::Error::other("endpoint queue lock poisoned"))
    }

    pub fn drain_frame(&self) -> io::Result<Option<Vec<u8>>> {
        let mut queue = self.lock()?;
        if queue.closed {
            return Err(io::Error::new(
                io::ErrorKind::BrokenPipe,
                "endpoint disconnected",
            ));
        }
        let frame = queue.frames.pop_front();
        if let Some(frame) = &frame {
            queue.bytes -= frame.len();
        }
        Ok(frame)
    }
}

impl EndpointTransport for OutboundQueue {
    fn send(&mut self, message: &ClientMessage) -> io::Result<()> {
        let mut frame = Vec::new();
        write_message(&mut frame, message)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
        let mut queue = self.lock()?;
        if queue.closed {
            return Err(io::Error::new(
                io::ErrorKind::BrokenPipe,
                "endpoint disconnected",
            ));
        }
        let Some(bytes) = queue
            .bytes
            .checked_add(frame.len())
            .filter(|bytes| *bytes <= queue.limits.bytes)
        else {
            return Err(io::Error::new(
                io::ErrorKind::ConnectionAborted,
                "endpoint byte budget exceeded",
            ));
        };
        if queue.frames.len() >= queue.limits.messages {
            return Err(io::Error::new(
                io::ErrorKind::ConnectionAborted,
                "endpoint message budget exceeded",
            ));
        }
        queue.bytes = bytes;
        queue.frames.push_back(frame);
        Ok(())
    }

    fn disconnect(&mut self) {
        if let Ok(mut queue) = self.lock() {
            queue.closed = true;
            queue.frames.clear();
            queue.bytes = 0;
        }
    }

    fn flush(&mut self, _deadline: std::time::Instant) -> io::Result<()> {
        if self.lock()?.frames.is_empty() {
            Ok(())
        } else {
            Err(io::Error::new(
                io::ErrorKind::WouldBlock,
                "caller must drain endpoint frames",
            ))
        }
    }
}
