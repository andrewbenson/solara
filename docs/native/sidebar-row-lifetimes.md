# Sidebar row identity and lifetime contract (layout Patch 5)

- Native layout opts in; legacy realization stays compatible.
- Logical layout, content height, number order, drop anchors and accessibility rows remain complete when views are absent.
- Bound rows equal target or active presentation intersections with region clips and ancestor/profile clipping. There is no row overscan.
- Exiting bindings commit active rename before detachment, clear work and identity, and enter concrete-kind/mode bins before entering rows allocate.
- Bins are bounded by recent viewport demand and trimmed when the viewport shrinks, independent of tab identity; hidden/stopped views clear bindings and bins.
- Every bind has a monotonically changing token. Favicon, rename begin/completion and animation cleanup from a prior binding are inert.
- Drag payload and model geometry survive source recycling without retaining source cells. Restoration only touches a current binding.
- Offscreen accessibility elements remain stable and scrolling/pressing them materializes the target. Numbering and active reveal use logical layout.
- Hidden profile pages retain metadata and scroll offsets only; partial swipe pages bind only within the pager intersection.
- Folder/group/live/rail auxiliary lists apply the same clip and reuse lifecycle.


The development native layout capability selects this contract. The legacy layout remains the eager control until the shipping cutover in Patch 11. `SidebarViewportTests`, `SidebarRowReuseTests`, `SidebarRecycleEditorTests`, `SidebarVirtualDragTests` and `SidebarAuxiliaryViewportTests` exercise the contract with actual native views. `sidebar-reuse-test.mjs` compares independent geometry intersections, allocation identities and Patch 1 counters in hidden app instances.
