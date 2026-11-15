/**
 * 翻页不再使用录音里的音。录音里的和弦和余音不能当成翻页位置。
 * 小节在 bake-screens.mjs 里从谱面切出，再用标准音合成来核对。
 */
console.error('不要用录音切翻页。请运行 node bake-screens.mjs');
process.exit(1);
