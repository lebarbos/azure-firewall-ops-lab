(function () {
  "use strict";

  var labels = {
    bash: "Cloud Shell · Bash",
    powershell: "VM · PowerShell",
    kql: "KQL · Log Analytics",
    json: "JSON",
    text: "Saída esperada"
  };

  function storageAvailable() {
    try {
      var key = "fwlab:v3:test";
      window.localStorage.setItem(key, "1");
      window.localStorage.removeItem(key);
      return true;
    } catch (error) {
      return false;
    }
  }

  var canStore = storageAvailable();

  function key(prefix, id) {
    return "fwlab:v3:" + prefix + ":" + id;
  }

  function readStored(name) {
    if (!canStore) return null;
    try { return window.localStorage.getItem(name); } catch (error) { return null; }
  }

  function writeStored(name, value) {
    if (!canStore) return;
    try { window.localStorage.setItem(name, value); } catch (error) { /* degrade silently */ }
  }

  function removeStored(name) {
    if (!canStore) return;
    try { window.localStorage.removeItem(name); } catch (error) { /* degrade silently */ }
  }

  function copyText(text, button) {
    function done(ok) {
      var original = button.textContent;
      button.textContent = ok ? "Copiado" : "Falhou";
      window.setTimeout(function () { button.textContent = original; }, 1400);
    }
    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(text).then(function () { done(true); }, function () { fallback(); });
    } else {
      fallback();
    }
    function fallback() {
      var textarea = document.createElement("textarea");
      textarea.value = text;
      textarea.setAttribute("readonly", "");
      textarea.style.position = "fixed";
      textarea.style.top = "-1000px";
      document.body.appendChild(textarea);
      textarea.select();
      try { done(document.execCommand("copy")); } catch (error) { done(false); }
      textarea.remove();
    }
  }

  function enhanceCodeBlocks() {
    document.querySelectorAll("pre.code").forEach(function (pre) {
      var lang = pre.getAttribute("data-lang") || "text";
      pre.setAttribute("data-label", labels[lang] || lang.toUpperCase());
      var button = document.createElement("button");
      button.type = "button";
      button.className = "copy-button";
      button.textContent = "Copiar";
      button.addEventListener("click", function () {
        // Só o <code>: o próprio botão fica dentro do <pre> e não pode ir junto.
        var code = pre.querySelector("code") || pre;
        copyText(code.textContent.replace(/^\n+|\s+$/g, ""), button);
      });
      pre.appendChild(button);
    });
  }

  var trackables = [];

  function updateProgress() {
    var done = trackables.filter(function (el) { return el.classList.contains("is-done"); }).length;
    var total = trackables.length;
    var count = document.getElementById("progress-count");
    var fill = document.getElementById("progress-fill");
    if (count) count.textContent = done + "/" + total;
    if (fill) fill.style.width = total ? Math.round(done * 100 / total) + "%" : "0";
    document.querySelectorAll(".toc a").forEach(function (link) {
      var target = link.getAttribute("href");
      if (!target || target.charAt(0) !== "#") return;
      var item = document.getElementById(target.slice(1));
      link.classList.toggle("done", !!item && item.classList.contains("is-done"));
    });
  }

  function enhanceProgress() {
    // Capítulos de referência (data-progress="off") usam .step só para layout: não contam no progresso.
    trackables = Array.prototype.slice.call(document.querySelectorAll(".step[id], .experiment[id]")).filter(function (item) {
      var chapter = item.closest("section.chapter");
      return !(chapter && chapter.getAttribute("data-progress") === "off");
    });
    trackables.forEach(function (item) {
      var id = item.id;
      var label = document.createElement("label");
      label.className = "done-control";
      var checkbox = document.createElement("input");
      checkbox.type = "checkbox";
      checkbox.checked = readStored(key("done", id)) === "1";
      item.classList.toggle("is-done", checkbox.checked);
      checkbox.addEventListener("change", function () {
        item.classList.toggle("is-done", checkbox.checked);
        if (checkbox.checked) writeStored(key("done", id), "1");
        else removeStored(key("done", id));
        updateProgress();
      });
      label.appendChild(checkbox);
      label.appendChild(document.createTextNode("Concluído"));
      item.insertBefore(label, item.firstChild);
    });
    var reset = document.getElementById("reset-progress");
    if (reset) {
      reset.addEventListener("click", function () {
        if (!window.confirm("Zerar progresso e previsões salvas neste navegador?")) return;
        trackables.forEach(function (item) {
          removeStored(key("done", item.id));
          item.classList.remove("is-done");
          var checkbox = item.querySelector(".done-control input");
          if (checkbox) checkbox.checked = false;
        });
        document.querySelectorAll(".predict[id], .predict[data-predict-id]").forEach(function (predict) {
          var pid = predict.getAttribute("data-predict-id") || predict.id || predict.closest("[id]").id;
          removeStored(key("predict", pid));
          var textarea = predict.querySelector("textarea");
          if (textarea) textarea.value = "";
        });
        updateProgress();
      });
    }
    updateProgress();
  }

  function enhancePredictions() {
    document.querySelectorAll(".predict").forEach(function (box, index) {
      var owner = box.closest("[id]");
      var id = box.getAttribute("data-predict-id") || (owner ? owner.id : "predict-" + index);
      box.setAttribute("data-predict-id", id);
      var textarea = document.createElement("textarea");
      textarea.setAttribute("aria-label", "Sua previsão para " + id);
      textarea.placeholder = "Escreva sua previsão antes de testar.";
      textarea.value = readStored(key("predict", id)) || "";
      textarea.addEventListener("input", function () {
        writeStored(key("predict", id), textarea.value);
      });
      box.appendChild(textarea);
    });
  }

  function enhanceNav() {
    var links = Array.prototype.slice.call(document.querySelectorAll(".toc a[href^='#']"));
    if (!("IntersectionObserver" in window)) return;
    var observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (!entry.isIntersecting) return;
        links.forEach(function (link) { link.classList.remove("active"); });
        var active = document.querySelector(".toc a[href='#" + entry.target.id + "']");
        if (active) active.classList.add("active");
      });
    }, { rootMargin: "-20% 0px -70% 0px", threshold: 0.01 });
    links.forEach(function (link) {
      var target = document.getElementById(link.getAttribute("href").slice(1));
      if (target) observer.observe(target);
    });
  }

  function enhanceMenu() {
    var button = document.querySelector(".menu-toggle");
    if (!button) return;
    button.addEventListener("click", function () {
      var open = !document.body.classList.contains("nav-open");
      document.body.classList.toggle("nav-open", open);
      button.setAttribute("aria-expanded", String(open));
    });
    document.querySelectorAll(".toc a").forEach(function (link) {
      link.addEventListener("click", function () {
        document.body.classList.remove("nav-open");
        button.setAttribute("aria-expanded", "false");
      });
    });
  }

  var openDetailsBeforePrint = [];

  function enhancePrint() {
    window.addEventListener("beforeprint", function () {
      openDetailsBeforePrint = [];
      document.querySelectorAll("details").forEach(function (details) {
        if (!details.open) {
          openDetailsBeforePrint.push(details);
          details.open = true;
        }
      });
    });
    window.addEventListener("afterprint", function () {
      openDetailsBeforePrint.forEach(function (details) { details.open = false; });
      openDetailsBeforePrint = [];
    });
  }

  function enhanceTheme() {
    var root = document.documentElement;
    var buttons = Array.prototype.slice.call(document.querySelectorAll("[data-theme-choice]"));
    var media = window.matchMedia ? window.matchMedia("(prefers-color-scheme: dark)") : null;
    var storeKey = "fwlab:v3:theme";

    function apply(pref) {
      var dark = pref === "dark" || (pref === "auto" && !!media && media.matches);
      root.setAttribute("data-theme", dark ? "dark" : "light");
      root.setAttribute("data-theme-pref", pref);
      buttons.forEach(function (button) {
        button.setAttribute("aria-pressed", String(button.getAttribute("data-theme-choice") === pref));
      });
    }

    var stored = readStored(storeKey);
    apply(stored === "light" || stored === "dark" ? stored : "auto");

    buttons.forEach(function (button) {
      button.addEventListener("click", function () {
        var pref = button.getAttribute("data-theme-choice");
        if (pref === "auto") removeStored(storeKey); else writeStored(storeKey, pref);
        apply(pref);
      });
    });

    if (media) {
      var onChange = function () {
        if (root.getAttribute("data-theme-pref") === "auto") apply("auto");
      };
      if (media.addEventListener) media.addEventListener("change", onChange);
      else if (media.addListener) media.addListener(onChange);
    }
  }

  enhanceTheme();
  enhanceCodeBlocks();
  enhanceProgress();
  enhancePredictions();
  enhanceNav();
  enhanceMenu();
  enhancePrint();
}());
