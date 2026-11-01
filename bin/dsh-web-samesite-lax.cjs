'use strict';
/**
 * dsh-web-samesite-lax — 运行时补丁：把浏览器会话 cookie 的 SameSite=Strict 改成 Lax。
 *
 * 为什么需要：
 *   安卓 Chrome 把「装到桌面的 WebAPK」冷启动时的那次根导航判定为 cross-site
 *   （Sec-Fetch-Site: cross-site），浏览器因此不会带上 SameSite=Strict 的
 *   dsh-auth-* cookie，服务端 authorizeIndex() 只能返回
 *   "dsh web authentication required; reopen the URL printed by dsh web."
 *   同一个地址在普通标签页里正常，装成 App 就 401；桌面端从聊天/邮件点链接进来也一样。
 *   上游已知问题：deepseek-ai/deepseek-harness#5362（0.2.1-rc.5 仍未修）。
 *
 * 做了什么：
 *   只改名字以 dsh-auth- 开头的 Set-Cookie，把 SameSite=Strict 换成 SameSite=Lax。
 *   其它 cookie 一律不碰。Lax 在「跨站顶层 GET 导航」上会发送，所以冷启动能拿到首页；
 *   首页之后的 /api、WebSocket 都是同源请求，行为不变。
 *
 * 注意：
 *   cookie 的属性是签发时定死的，已经存在浏览器里的 Strict cookie 不会自己变。
 *   换上新补丁后，要用 dsh-web-url 打印的地址重新打开一次，让服务端重签一次；
 *   之后冷启动才不再 401。
 *
 * 加载方式：
 *   Electron 以 node 方式跑 CLI 时会忽略 NODE_OPTIONS，所以 dsh-web 直接调用
 *   Electron 二进制并加 `--require <本文件>`。
 *
 * 关掉它：删掉本文件，dsh-web 会退回原始的 CLI wrapper。
 */

const http = require('node:http');

const SESSION_COOKIE = /^\s*dsh-auth-/;

/** @param {unknown} value @returns {unknown} */
function lax(value) {
	if (typeof value !== 'string' || !SESSION_COOKIE.test(value)) return value;
	return value.replace(/;\s*SameSite=Strict/i, '; SameSite=Lax');
}

/** @param {any} headers @returns {any} */
function patchHeaders(headers) {
	if (headers === null || typeof headers !== 'object' || Array.isArray(headers)) return headers;
	let touched = false;
	/** @type {Record<string, any>} */
	const out = {};
	for (const key of Object.keys(headers)) {
		const value = headers[key];
		if (key.toLowerCase() !== 'set-cookie') {
			out[key] = value;
			continue;
		}
		out[key] = Array.isArray(value) ? value.map(lax) : lax(value);
		touched = true;
	}
	return touched ? out : headers;
}

const proto = http.ServerResponse.prototype;
const writeHead = proto.writeHead;
proto.writeHead = function patchedWriteHead(statusCode, a, b) {
	return typeof a === 'string'
		? writeHead.call(this, statusCode, a, patchHeaders(b))
		: writeHead.call(this, statusCode, patchHeaders(a));
};

const setHeader = proto.setHeader;
proto.setHeader = function patchedSetHeader(name, value) {
	if (String(name).toLowerCase() === 'set-cookie') {
		value = Array.isArray(value) ? value.map(lax) : lax(value);
	}
	return setHeader.call(this, name, value);
};
