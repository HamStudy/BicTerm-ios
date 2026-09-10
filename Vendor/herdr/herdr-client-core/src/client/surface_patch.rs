// Derived from herdr b99002ac99b09e00b4ca692436cb15a6b0d676f1 src/client/shell/surface_patch.rs (8:55 94:167), Apache-2.0.
// Modified: public library visibility, transport-free state, Home instead of Local.
pub enum ClientPaneSurfacePatchOutcome {
    Rejected,
    Applied,
}

fn row_fits_frame(row: &crate::protocol::PaneSurfacePatchRow, frame: &FrameData) -> bool {
    row.x
        .saturating_add(row.cells.len().min(u16::MAX as usize) as u16)
        <= frame.width
        && row.y < frame.height
}

fn apply_row(row: &crate::protocol::PaneSurfacePatchRow, frame: &mut FrameData) -> bool {
    if !row_fits_frame(row, frame) {
        return false;
    }
    let start = usize::from(row.y) * usize::from(frame.width) + usize::from(row.x);
    let end = start + row.cells.len();
    if end > frame.cells.len() {
        return false;
    }
    frame.cells[start..end].clone_from_slice(&row.cells);
    true
}

fn apply_patch_to_surface(
    surface: &mut crate::protocol::PaneSurfaceFrame,
    patch: &crate::protocol::PaneSurfacePatch,
) -> bool {
    for row in &patch.rows {
        if !apply_row(row, &mut surface.frame) {
            return false;
        }
    }
    for updated in &patch.panes {
        let Some(existing) = surface
            .panes
            .iter_mut()
            .find(|pane| pane.pane_id == updated.pane_id)
        else {
            return false;
        };
        *existing = updated.clone();
    }
    surface.frame.cursor = patch.cursor.clone();
    surface.surface_revision = patch.surface_revision;
    true
}
fn pane_geometry_matches(
    left: &crate::protocol::PaneSurfacePane,
    right: &crate::protocol::PaneSurfacePane,
) -> bool {
    left.pane_id == right.pane_id
        && left.rect == right.rect
        && left.inner_rect == right.inner_rect
        && left.focused == right.focused
        && left.pixel_width == right.pixel_width
        && left.pixel_height == right.pixel_height
}

impl ClientShellState {
    pub fn apply_pane_surface_patch(
        &mut self,
        patch: crate::protocol::PaneSurfacePatch,
    ) -> ClientPaneSurfacePatchOutcome {
        let Some(current) = self.surface.as_ref() else {
            return ClientPaneSurfacePatchOutcome::Rejected;
        };
        if patch.boot_id != current.boot_id
            || patch.projection_revision != current.projection_revision
            || patch.base_surface_revision != current.surface_revision
            || patch.surface_revision != current.surface_revision.saturating_add(1)
            || current.popup.is_some()
            || !current.graphics.placements.is_empty()
            || !current.graphics.retained_assets.is_empty()
        {
            return ClientPaneSurfacePatchOutcome::Rejected;
        }

        for updated in &patch.panes {
            let Some(existing) = current
                .panes
                .iter()
                .find(|pane| pane.pane_id == updated.pane_id)
            else {
                return ClientPaneSurfacePatchOutcome::Rejected;
            };
            if !pane_geometry_matches(existing, updated) {
                return ClientPaneSurfacePatchOutcome::Rejected;
            }
        }
        for row in &patch.rows {
            if !row_fits_frame(row, &current.frame)
                || row.cells.is_empty()
                || !patch.panes.iter().any(|pane| {
                    let terminal_row = row.x >= pane.inner_rect.x
                        && row.y >= pane.inner_rect.y
                        && row.y < pane.inner_rect.y.saturating_add(pane.inner_rect.height)
                        && row
                            .x
                            .saturating_add(row.cells.len().min(u16::MAX as usize) as u16)
                            <= pane.inner_rect.x.saturating_add(pane.inner_rect.width);
                    let scrollbar_rect = pane.scrollbar_rect.or_else(|| {
                        current
                            .panes
                            .iter()
                            .find(|existing| existing.pane_id == pane.pane_id)
                            .and_then(|existing| existing.scrollbar_rect)
                    });
                    let scrollbar_row = scrollbar_rect.is_some_and(|rect| {
                        row.x == rect.x
                            && row.y >= rect.y
                            && row.y < rect.y.saturating_add(rect.height)
                            && row.cells.len() == usize::from(rect.width)
                    });
                    terminal_row || scrollbar_row
                })
            {
                return ClientPaneSurfacePatchOutcome::Rejected;
            }
        }

        let mut next = current.clone();
        if !apply_patch_to_surface(&mut next, &patch)
            || crate::surface::validate_surface(&next).is_err()
        {
            return ClientPaneSurfacePatchOutcome::Rejected;
        }
        self.surface = Some(next);
        ClientPaneSurfacePatchOutcome::Applied
    }
}
use super::ClientShellState;
use crate::protocol::FrameData;
