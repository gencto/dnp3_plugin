//! Little-endian binary reader/writer used for the hot-path wire formats exchanged with Dart.

use crate::core::{Error, Result};

pub struct Writer {
    pub buf: Vec<u8>,
}

impl Writer {
    pub fn with_capacity(cap: usize) -> Self {
        Self {
            buf: Vec::with_capacity(cap),
        }
    }

    #[inline]
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    pub fn len(&self) -> usize {
        self.buf.len()
    }

    #[inline]
    pub fn u8(&mut self, x: u8) {
        self.buf.push(x);
    }

    #[inline]
    pub fn u16(&mut self, x: u16) {
        self.buf.extend_from_slice(&x.to_le_bytes());
    }

    #[inline]
    pub fn u32(&mut self, x: u32) {
        self.buf.extend_from_slice(&x.to_le_bytes());
    }

    #[inline]
    pub fn u64(&mut self, x: u64) {
        self.buf.extend_from_slice(&x.to_le_bytes());
    }

    #[inline]
    pub fn i64(&mut self, x: i64) {
        self.buf.extend_from_slice(&x.to_le_bytes());
    }

    #[inline]
    pub fn f64(&mut self, x: f64) {
        self.buf.extend_from_slice(&x.to_le_bytes());
    }

    #[inline]
    pub fn zeros(&mut self, n: usize) {
        self.buf.resize(self.buf.len() + n, 0);
    }

    #[inline]
    pub fn bytes(&mut self, x: &[u8]) {
        self.buf.extend_from_slice(x);
    }

    /// write a u32 length prefix followed by the bytes, padded to a multiple of 4
    pub fn blob(&mut self, x: &[u8]) {
        self.u32(x.len() as u32);
        self.bytes(x);
        self.pad4();
    }

    #[inline]
    pub fn pad4(&mut self) {
        let rem = self.buf.len() % 4;
        if rem != 0 {
            self.zeros(4 - rem);
        }
    }

    #[inline]
    pub fn patch_u16(&mut self, pos: usize, x: u16) {
        self.buf[pos..pos + 2].copy_from_slice(&x.to_le_bytes());
    }

    #[inline]
    pub fn patch_u32(&mut self, pos: usize, x: u32) {
        self.buf[pos..pos + 4].copy_from_slice(&x.to_le_bytes());
    }

    pub fn finish(self) -> Vec<u8> {
        self.buf
    }
}

pub struct Reader<'a> {
    data: &'a [u8],
    pos: usize,
}

fn eof() -> Error {
    Error::arg("unexpected end of binary buffer")
}

impl<'a> Reader<'a> {
    pub fn new(data: &'a [u8]) -> Self {
        Self { data, pos: 0 }
    }

    #[inline]
    pub fn remaining(&self) -> usize {
        self.data.len() - self.pos
    }

    #[inline]
    pub fn is_empty(&self) -> bool {
        self.remaining() == 0
    }

    #[inline]
    pub fn take(&mut self, n: usize) -> Result<&'a [u8]> {
        if self.remaining() < n {
            return Err(eof());
        }
        let s = &self.data[self.pos..self.pos + n];
        self.pos += n;
        Ok(s)
    }

    #[inline]
    pub fn skip(&mut self, n: usize) -> Result<()> {
        self.take(n).map(|_| ())
    }

    #[inline]
    pub fn u8(&mut self) -> Result<u8> {
        Ok(self.take(1)?[0])
    }

    #[inline]
    pub fn u16(&mut self) -> Result<u16> {
        Ok(u16::from_le_bytes(self.take(2)?.try_into().unwrap()))
    }

    #[inline]
    pub fn i16(&mut self) -> Result<i16> {
        Ok(i16::from_le_bytes(self.take(2)?.try_into().unwrap()))
    }

    #[inline]
    pub fn u32(&mut self) -> Result<u32> {
        Ok(u32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }

    #[inline]
    pub fn i32(&mut self) -> Result<i32> {
        Ok(i32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }

    #[inline]
    pub fn f32(&mut self) -> Result<f32> {
        Ok(f32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }

    #[inline]
    pub fn u64(&mut self) -> Result<u64> {
        Ok(u64::from_le_bytes(self.take(8)?.try_into().unwrap()))
    }

    #[inline]
    pub fn i64(&mut self) -> Result<i64> {
        Ok(i64::from_le_bytes(self.take(8)?.try_into().unwrap()))
    }

    #[inline]
    pub fn f64(&mut self) -> Result<f64> {
        Ok(f64::from_le_bytes(self.take(8)?.try_into().unwrap()))
    }

    /// read a blob written by [`Writer::blob`]
    pub fn blob(&mut self) -> Result<&'a [u8]> {
        let len = self.u32()? as usize;
        let data = self.take(len)?;
        let rem = len % 4;
        if rem != 0 {
            self.skip(4 - rem)?;
        }
        Ok(data)
    }

    pub fn string(&mut self) -> Result<String> {
        let b = self.blob()?;
        String::from_utf8(b.to_vec()).map_err(|_| Error::arg("invalid UTF-8 in binary buffer"))
    }
}
