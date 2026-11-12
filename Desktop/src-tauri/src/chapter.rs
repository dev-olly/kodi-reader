use crate::Result;
use quick_xml::{events::Event, Reader};

/// EPUB content may use UTF-8 or UTF-16. The injected response is always UTF-8,
/// so an original UTF-16 XML declaration must not label the transcoded bytes.
pub(crate) fn decode(bytes: &[u8]) -> Result<String> {
    let utf16 = if bytes.starts_with(&[0xff, 0xfe]) {
        Some((true, &bytes[2..]))
    } else if bytes.starts_with(&[0xfe, 0xff]) {
        Some((false, &bytes[2..]))
    } else if bytes.starts_with(b"<\0?\0") {
        Some((true, bytes))
    } else if bytes.starts_with(b"\0<\0?") {
        Some((false, bytes))
    } else {
        None
    };
    let text = if let Some((little, bytes)) = utf16 {
        if bytes.len() % 2 != 0 {
            return Err("This chapter has incomplete UTF-16 text.".into());
        }
        let units = bytes
            .chunks_exact(2)
            .map(|pair| {
                if little {
                    u16::from_le_bytes([pair[0], pair[1]])
                } else {
                    u16::from_be_bytes([pair[0], pair[1]])
                }
            })
            .collect::<Vec<_>>();
        String::from_utf16(&units).map_err(|_| "This chapter has invalid UTF-16 text.")?
    } else {
        std::str::from_utf8(bytes.strip_prefix(&[0xef, 0xbb, 0xbf]).unwrap_or(bytes))
            .map_err(|_| "This chapter's text encoding is unsupported.")?
            .to_owned()
    };
    if text.starts_with("<?xml") {
        if let Some(end) = text.find("?>") {
            return Ok(text[end + 2..].to_owned());
        }
    }
    Ok(text)
}

pub(crate) fn inject(html: &str, tags: &str) -> Result<String> {
    let mut reader = Reader::from_str(html);
    loop {
        let start = reader.buffer_position();
        match reader
            .read_event()
            .map_err(|error| format!("This chapter's markup is unreadable: {error}"))?
        {
            Event::Start(element) => {
                let qualified = element.name();
                let name = qualified
                    .as_ref()
                    .rsplit(|byte| *byte == b':')
                    .next()
                    .unwrap_or_default();
                if name.eq_ignore_ascii_case(b"head") {
                    let end = reader.buffer_position();
                    return Ok(format!("{}{}{}", &html[..end], tags, &html[end..]));
                }
                if name.eq_ignore_ascii_case(b"body") {
                    return Ok(format!(
                        "{}<head xmlns=\"http://www.w3.org/1999/xhtml\">{tags}</head>{}",
                        &html[..start],
                        &html[start..]
                    ));
                }
            }
            Event::Empty(element)
                if element.local_name().as_ref().eq_ignore_ascii_case(b"head") =>
            {
                let end = reader.buffer_position();
                let qualified = std::str::from_utf8(element.name().as_ref())
                    .map_err(|_| "Invalid chapter head element")?
                    .to_owned();
                let opening = html[start..end]
                    .trim_end()
                    .strip_suffix("/>")
                    .ok_or("Invalid chapter head element")?;
                return Ok(format!(
                    "{}{opening}>{tags}</{qualified}>{}",
                    &html[..start],
                    &html[end..]
                ));
            }
            Event::Eof => return Err("This chapter has no readable HTML content.".into()),
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn utf16_chapters_become_utf8_without_a_stale_encoding_declaration() {
        let text = "<?xml version=\"1.0\" encoding=\"UTF-16\"?><html><head><title>章</title></head><body>😀</body></html>";
        for little in [true, false] {
            let mut bytes = if little {
                vec![0xff, 0xfe]
            } else {
                vec![0xfe, 0xff]
            };
            for unit in text.encode_utf16() {
                bytes.extend(if little {
                    unit.to_le_bytes()
                } else {
                    unit.to_be_bytes()
                });
            }
            let decoded = decode(&bytes).unwrap();
            assert!(decoded.contains("章"));
            assert!(decoded.contains("😀"));
            assert!(!decoded.contains("UTF-16"));
            assert!(inject(&decoded, "RUNTIME")
                .unwrap()
                .contains("<head>RUNTIME<title>"));
        }
        assert!(decode(&[0xff, 0xfe, 0]).is_err());
    }

    #[test]
    fn actual_prefixed_head_is_used_instead_of_a_commented_head() {
        let source = "<!-- <head>sample</head> --><h:html xmlns:h=\"http://www.w3.org/1999/xhtml\"><h:head id=\"real\"><h:title>Book</h:title></h:head><h:body>Text</h:body></h:html>";
        let result = inject(source, "RUNTIME").unwrap();
        assert!(result.starts_with("<!-- <head>sample</head> -->"));
        assert!(result.contains("<h:head id=\"real\">RUNTIME<h:title>"));
    }

    #[test]
    fn empty_or_implicit_heads_receive_the_reader_runtime() {
        assert!(inject("<html><head/><body>Text</body></html>", "RUNTIME")
            .unwrap()
            .contains("<head>RUNTIME</head>"));
        let result = inject("<html><body>Text</body></html>", "RUNTIME").unwrap();
        assert!(
            result.contains("<head xmlns=\"http://www.w3.org/1999/xhtml\">RUNTIME</head><body>")
        );
        assert_eq!(
            decode(b"\xef\xbb\xbf<html></html>").unwrap(),
            "<html></html>"
        );
    }
}
