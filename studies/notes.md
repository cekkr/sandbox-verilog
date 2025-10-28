Author's notes file

Next steps:
- Improve examples/neutal_activation_field: efficiency with "not used" units, like for cone-shaped models, where the grid size changes belong the layers, in practice "de-activating" some units for smaller grids.



# Doubt about "water flux" concept:
I need to confirm an approach to the project (updating [README.md](README.md) and [AI_REFERENCE.md](AI_REFERENCE.md) concepts if needed):
The weights of a unit should contains not only a weight-bias, but:
- Capability (how much "water" it could contain)
- Connection with a neighbour unit "sand size" (the larger it is, the more water can pass through) and "friction" (the smaller the amount of sand, the more pressure it may require to initiate or maintain flow toward a neighboring unit). This must also be compared to the same water pressure from the neighboring unit, which counteracts the overall flow.

AI's blablah:
Your weight tuple idea meshes with the current flux/pressure pipeline: capability maps neatly onto each grain’s local storage/overflow guard, sand-size becomes the per-edge coupling already hinted at by the directional weights, and friction is the counter-pressure term that should look at both cells before letting flow proceed.

README.md:106 already introduces directional weights; expand that paragraph into a definition of a “unit weight” that now carries (capacity, channel, friction) and note that OP_WATER_FLUX clamps the transfer by both parties’ capability and friction. I’d follow it with a short formula or bullet list showing how outgoing flow = min(self.capability, neighbor.capability) × channel – friction, with the opposing cell’s pressure term subtracting from the net flux.
Right after the CSR table (README.md:115), add a sentence clarifying which CSR bank feeds each component: capability as the saturation threshold, channel coefficients in the TOP/BOTTOM/SIDE slots, and friction derived from the overflow/pressure gains so readers know how to program it.
In AI_REFERENCE.md:28, under CONFIG_CORE, note that unit weights are now a 3-tuple and list where each component lives (directional CSR fields + pressure gain). Also add a line beneath PROCESSING_ELEMENT explaining that flux/pressure ops compare both cells’ capability/friction to decide the final delta.
If you later introduce new registers (e.g., an explicit CSR_UNIT_CAPACITY), mirror those names in both documents so the glossary stays authoritative.
Once the docs describe the tuple, the implementation work becomes clearer: ensure the PE stores per-edge friction, gates flux with bilateral capacity checks, and feeds the counter-pressure term into OP_PRESSURE. Natural next steps: 1) update the README/AI reference as described; 2) audit sand_pe/scheduler CSRs to confirm each component is wired through.

Flux Tuple Update

Reworked the streaming raster PE flux path to evaluate bilateral flow with the {capability, channel, friction} tuple, gating the vertical friction via CSR_UNIT_CTRL[2:1] and using the pressure gain for planar edges so the flow is clamped by both resistance and capacity (rtl/sand_engine_raster.v:122, rtl/sand_engine_raster.v:566).
Added the same directional-flow helper and accumulator to the legacy sand_pe so grid instantiations obey the new tuple mapping when OP_WATER_FLUX is selected (rtl/sand_pe.v:70, rtl/sand_pe.v:201).
Noted the control-bit behaviour in the docs so it’s clear how to program friction for the vertical channels (README.md:104, AI_REFERENCE.md:28).
Validation

python3 examples/galton_board/run.py --samples 0
Natural next steps:

- Sweep a few flux coefficient combinations to confirm the new friction gating converges as expected on your target workloads.
- Re-run other example harnesses (e.g., neural edge/activation) to ensure the bilateral flow math keeps their dynamics stable.