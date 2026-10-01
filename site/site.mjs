// Shared by every page.
// The menu bar clock shows the visitor's own time, like the real one.
const clock = document.querySelector('.clock');
if (clock) {
  const day = new Intl.DateTimeFormat(undefined, { weekday: 'short' });
  const time = new Intl.DateTimeFormat(undefined, { hour: 'numeric', minute: '2-digit' });
  const show = () => { const now = new Date(); clock.textContent = `${day.format(now)} ${time.format(now)}`; };
  show(); setInterval(show, 15000);
}

// Open a linked help section, including direct links and browser Back.
function reveal(hash) {
  const target = hash && document.getElementById(hash.slice(1));
  if (target instanceof HTMLDetailsElement) target.open = true;
}
document.querySelectorAll('a[href^="#"]').forEach(link => link.addEventListener('click', () => reveal(link.hash)));
addEventListener('hashchange', () => reveal(location.hash));
reveal(location.hash);
