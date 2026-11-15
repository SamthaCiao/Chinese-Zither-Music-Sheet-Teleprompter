export default {
  onLaunch() { console.log('[guzheng] agent launched'); },
  onShow(options) {
    const q = options && (options.query || options);
    if (!q) return;
    try {
      const pages = (typeof getCurrentPages === 'function') ? getCurrentPages() : [];
      const page = pages && pages[pages.length - 1];
      if (page && page.acceptQuery) page.acceptQuery(q);
    } catch (e) {}
  },
  onHide() { console.log('[guzheng] agent hidden'); }
};