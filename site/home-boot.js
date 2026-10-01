// Runs before first paint: hide the hero's flying words so they arrive instead of flashing.
// Without motion (or without JavaScript) the hero simply shows its finished state.
if (!matchMedia('(prefers-reduced-motion: reduce)').matches) document.documentElement.classList.add('js-motion');
