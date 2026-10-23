// Skin carousel on the home page (#0168). No libraries.
// The track is a horizontal scroll-snap strip, so touch swipe and trackpad scrolling are native;
// this script adds the dots, mouse dragging, the arrow keys and a change every 3 seconds.
// Autoplay pauses while the pointer is over the carousel or focus is inside it, while the page is hidden,
// and never starts when the visitor prefers reduced motion.
(function () {
  "use strict";
  var INTERVAL_MS = 3000;

  document.querySelectorAll("[data-carousel]").forEach(function (root) {
    var track = root.querySelector(".carousel-track");
    var slides = Array.prototype.slice.call(track.querySelectorAll(".carousel-slide"));
    var dotsBox = root.querySelector(".carousel-dots");
    var label = root.querySelector("[data-carousel-label]");
    if (slides.length < 2 || !dotsBox) return;

    var reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
    var current = 0;
    var timer = null;
    var hovering = false;
    var focused = false;

    var dots = slides.map(function (slide, i) {
      var dot = document.createElement("button");
      dot.type = "button";
      dot.className = "carousel-dot";
      dot.setAttribute("aria-label", "Show " + (slide.getAttribute("data-name") || "slide " + (i + 1)));
      dot.addEventListener("click", function () { go(i, true); });
      dotsBox.appendChild(dot);
      return dot;
    });

    function behavior() { return reduceMotion.matches ? "auto" : "smooth"; }

    function mark(i) {
      current = i;
      dots.forEach(function (d, j) {
        if (j === i) d.setAttribute("aria-current", "true"); else d.removeAttribute("aria-current");
      });
      slides.forEach(function (s, j) { s.setAttribute("aria-hidden", j === i ? "false" : "true"); });
      if (label) label.textContent = slides[i].getAttribute("data-name") || "";
    }

    function go(i, fromUser) {
      i = (i + slides.length) % slides.length;
      track.scrollTo({ left: slides[i].offsetLeft - track.offsetLeft, behavior: behavior() });
      mark(i);
      if (fromUser) restart();
    }

    function canPlay() {
      return !reduceMotion.matches && !hovering && !focused && !dragging && document.visibilityState === "visible";
    }
    function stop() { if (timer) { clearInterval(timer); timer = null; } }
    function restart() {
      stop();
      if (canPlay()) timer = setInterval(function () { go(current + 1, false); }, INTERVAL_MS);
    }

    // Keep the dots in step when the visitor swipes or scrolls the strip themselves.
    var settle = null;
    track.addEventListener("scroll", function () {
      clearTimeout(settle);
      settle = setTimeout(function () {
        var i = Math.round(track.scrollLeft / track.clientWidth);
        i = Math.max(0, Math.min(slides.length - 1, i));
        if (i !== current) { mark(i); restart(); }
      }, 80);
    }, { passive: true });

    // Mouse dragging; touch and pen already scroll the strip natively.
    var dragging = false, startX = 0, startLeft = 0, moved = false;
    track.addEventListener("pointerdown", function (e) {
      if (e.pointerType !== "mouse" || e.button !== 0) return;
      dragging = true; moved = false; startX = e.clientX; startLeft = track.scrollLeft;
      track.classList.add("is-dragging");
      track.setPointerCapture(e.pointerId);
      stop();
    });
    track.addEventListener("pointermove", function (e) {
      if (!dragging) return;
      var dx = e.clientX - startX;
      if (Math.abs(dx) > 4) moved = true;
      track.scrollLeft = startLeft - dx;
    });
    function endDrag(e) {
      if (!dragging) return;
      dragging = false;
      track.classList.remove("is-dragging");
      var dx = e.clientX - startX;
      var step = Math.abs(dx) > track.clientWidth * 0.15 ? (dx < 0 ? 1 : -1) : 0;
      go(current + step, true);
    }
    track.addEventListener("pointerup", endDrag);
    track.addEventListener("pointercancel", endDrag);
    track.addEventListener("click", function (e) { if (moved) { e.preventDefault(); moved = false; } }, true);
    track.addEventListener("dragstart", function (e) { e.preventDefault(); });

    root.addEventListener("keydown", function (e) {
      if (e.key === "ArrowRight") { e.preventDefault(); go(current + 1, true); }
      else if (e.key === "ArrowLeft") { e.preventDefault(); go(current - 1, true); }
    });

    root.addEventListener("pointerenter", function (e) { if (e.pointerType === "mouse") { hovering = true; stop(); } });
    root.addEventListener("pointerleave", function () { hovering = false; restart(); });
    root.addEventListener("focusin", function () { focused = true; stop(); });
    root.addEventListener("focusout", function (e) {
      if (!root.contains(e.relatedTarget)) { focused = false; restart(); }
    });
    document.addEventListener("visibilitychange", restart);
    if (reduceMotion.addEventListener) reduceMotion.addEventListener("change", restart);
    window.addEventListener("resize", function () { go(current, false); });

    root.classList.add("is-ready");
    mark(0);
    restart();
  });
})();
