const sections = document.querySelectorAll('.doc-section[id]');
const tocLinks = document.querySelectorAll('.toc-strip a[href^="#"]');

const obs = new IntersectionObserver(entries => {
  entries.forEach(e => {
    if (e.isIntersecting) {
      tocLinks.forEach(l => l.classList.remove('active'));
      const a = document.querySelector(`.toc-strip a[href="#${e.target.id}"]`);
      if (a) {
        a.classList.add('active');
        a.scrollIntoView({ block: 'nearest', inline: 'center' });
      }
    }
  });
}, { rootMargin: '-5% 0px -80% 0px' });

sections.forEach(s => obs.observe(s));
