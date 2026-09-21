'use strict';
const examples = {
  english: { before: '오늘도 <mark>dkssud</mark>!', after: '오늘도 <mark>안녕</mark>!', hint: '영어로 잘못 친 부분을 선택했어요.' },
  jamo: { before: '<mark>ㅇㅏㄴㄴㅕㅇ</mark>! ㅋㅋㅋ', after: '<mark>안녕</mark>! ㅋㅋㅋ', hint: '합칠 자모를 선택했어요.' }
};
let mode = 'english';
const text = document.querySelector('#demo-text');
const caption = document.querySelector('#demo-caption');
const convert = document.querySelector('#convert');
function resetDemo() {
  text.innerHTML = examples[mode].before;
  caption.textContent = examples[mode].hint;
  convert.disabled = false;
}
document.querySelectorAll('[data-mode]').forEach(button => {
  button.addEventListener('click', () => {
    mode = button.dataset.mode;
    document.querySelectorAll('[data-mode]').forEach(tab => tab.setAttribute('aria-pressed', String(tab === button)));
    resetDemo();
  });
});
convert.addEventListener('click', () => {
  text.innerHTML = examples[mode].after;
  caption.textContent = '한큐에 변환했어요. 실제 앱에서는 우측 Option을 사용하세요.';
  convert.disabled = true;
});
document.querySelector('#reset').addEventListener('click', resetDemo);
