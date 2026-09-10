use crate::protocol::{FrameData, PaneSurfaceFrame, SurfaceRect};

fn frame_valid(frame: &FrameData) -> bool {
    frame.cells.len() == usize::from(frame.width) * usize::from(frame.height)
        && frame.cells.iter().all(|cell| {
            cell.hyperlink.is_none_or(|index| {
                usize::try_from(index).is_ok_and(|index| index < frame.hyperlinks.len())
            })
        })
        && frame
            .cursor
            .as_ref()
            .is_none_or(|cursor| cursor.x < frame.width && cursor.y < frame.height)
}

fn rect_fits(rect: SurfaceRect, frame: &FrameData) -> bool {
    rect.x
        .checked_add(rect.width)
        .is_some_and(|right| right <= frame.width)
        && rect
            .y
            .checked_add(rect.height)
            .is_some_and(|bottom| bottom <= frame.height)
}

pub fn validate_surface(surface: &PaneSurfaceFrame) -> Result<(), String> {
    if !frame_valid(&surface.frame)
        || !surface.panes.iter().all(|pane| {
            rect_fits(pane.rect, &surface.frame)
                && rect_fits(pane.inner_rect, &surface.frame)
                && pane
                    .scrollbar_rect
                    .is_none_or(|rect| rect_fits(rect, &surface.frame))
        })
        || surface
            .popup
            .as_ref()
            .is_some_and(|popup| !frame_valid(&popup.frame))
    {
        return Err("invalid surface cells, hyperlinks, cursor, or pane geometry".into());
    }
    let mut ids = std::collections::HashSet::new();
    if !surface.panes.iter().all(|pane| ids.insert(&pane.pane_id)) {
        return Err("duplicate pane identity in surface".into());
    }
    Ok(())
}
