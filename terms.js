'use strict';
const sourceURL = 'https://raw.githubusercontent.com/jungti1234/hanq/main/LICENSE';
const article = document.querySelector('#license-content');
const status = document.querySelector('#license-status');
const retry = document.querySelector('#license-retry');

// Build DOM nodes from Markdown without interpreting source text as HTML.
function renderMarkdown(markdown) {
  const fragment = document.createDocumentFragment();
  let paragraph = [];
  let list = null;
  function flushParagraph() {
    if (!paragraph.length) return;
    const element = document.createElement('p');
    element.textContent = paragraph.join('\n');
    fragment.append(element);
    paragraph = [];
  }
  for (const line of markdown.replace(/\r\n?/g, '\n').split('\n')) {
    const heading = /^(#{1,6})\s+(.+)$/.exec(line);
    const bullet = /^[-*+]\s+(.+)$/.exec(line);
    if (heading) {
      flushParagraph(); list = null;
      const element = document.createElement('h' + heading[1].length);
      element.textContent = heading[2];
      fragment.append(element);
    } else if (bullet) {
      flushParagraph();
      if (!list) { list = document.createElement('ul'); fragment.append(list); }
      const item = document.createElement('li');
      item.textContent = bullet[1];
      list.append(item);
    } else if (!line.trim()) {
      flushParagraph(); list = null;
    } else {
      list = null; paragraph.push(line);
    }
  }
  flushParagraph();
  return fragment;
}

async function loadLicense() {
  retry.hidden = true;
  article.replaceChildren();
  article.setAttribute('aria-busy', 'true');
  status.textContent = '최신 이용 조건을 불러오고 있어요.';
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 12000);
  try {
    const response = await fetch(sourceURL, { cache: 'no-store', credentials: 'omit', signal: controller.signal });
    if (!response.ok) throw new Error('License request failed');
    const markdown = await response.text();
    if (!markdown.trim() || !/^#\s+/m.test(markdown)) throw new Error('Invalid license response');
    article.replaceChildren(renderMarkdown(markdown));
    status.textContent = '';
  } catch {
    status.textContent = '이용 조건을 불러오지 못했어요. 다시 시도하거나 위의 ‘원문 보기’를 이용해주세요.';
    retry.hidden = false;
  } finally {
    clearTimeout(timeout);
    article.setAttribute('aria-busy', 'false');
  }
}
retry.addEventListener('click', loadLicense);
loadLicense();
