/*
 * iScream — a deliberately tiny IRC client for #radiolibre.
 *
 * Talks to Ergo over a WebSocket with the IRCv3 "text.ircv3.net" subprotocol:
 * one IRC line per text frame, no CRLF. Always same-origin /irc: in production
 * nginx routes it to Ergo; locally server.js does when CHAT_PROXY is set.
 *
 * Everything received is written with textContent — never innerHTML — so
 * nothing anyone types can become markup on another person's screen.
 */
(function () {
  'use strict';

  var CHANNEL = '#radiolibre';
  var MAX_LINES = 300;
  var URL_ = (location.protocol === 'https:' ? 'wss:' : 'ws:') + '//' + location.host + '/irc';
  var NICK_KEY = 'iscream.nick';

  var $ = function (id) { return document.getElementById(id); };
  var joinForm = $('chat-join');
  var nickInput = $('chat-nick');
  var chat = $('chat');
  var statusEl = $('chat-status');
  var log = $('chat-log');
  var sayForm = $('chat-say');
  var input = $('chat-input');

  var ws = null;
  var me = '';
  var wanted = '';
  var joined = false;
  var leaving = false;
  var retry = 0;
  var retryTimer = null;

  // ------------------------------------------------------------ helpers

  function store(k, v) {
    try { if (v === undefined) return localStorage.getItem(k); localStorage.setItem(k, v); } catch (e) { return null; }
  }

  // IRC nicknames: ASCII letters, digits and a few symbols, not starting with a digit or '-'.
  function cleanNick(raw) {
    var n = (raw || '').normalize('NFD').replace(/[̀-ͯ]/g, '')
      .replace(/\s+/g, '_').replace(/[^A-Za-z0-9_\-\[\]\\`^{}|]/g, '').slice(0, 20);
    if (!n || /^[0-9-]/.test(n)) n = 'anon' + (n ? '_' + n : '-' + Math.floor(1000 + Math.random() * 9000));
    return n.slice(0, 20);
  }

  // Colour, bold, italic, reset… codes are noise on a web page.
  function stripFormatting(s) {
    return s.replace(/\x03(\d{1,2}(,\d{1,2})?)?|[\x02\x0f\x11\x16\x1d\x1e\x1f]/g, '');
  }

  function parse(line) {
    var m = { tags: null, prefix: '', command: '', params: [] };
    var i = 0;
    if (line[0] === '@') { i = line.indexOf(' ') + 1; }
    if (line[i] === ':') { var sp = line.indexOf(' ', i); m.prefix = line.slice(i + 1, sp); i = sp + 1; }
    while (line[i] === ' ') i++;
    var rest = line.slice(i);
    var trail = rest.indexOf(' :');
    var head = trail >= 0 ? rest.slice(0, trail) : rest;
    var parts = head.split(' ').filter(Boolean);
    m.command = (parts.shift() || '').toUpperCase();
    m.params = parts;
    if (trail >= 0) m.params.push(rest.slice(trail + 2));
    m.nick = m.prefix.split('!')[0];
    return m;
  }

  function send(line) {
    if (ws && ws.readyState === 1) ws.send(line.replace(/[\r\n]/g, ' '));
  }

  function setStatus(text, state) {
    statusEl.textContent = text;
    statusEl.dataset.state = state || '';
  }

  function hhmm() {
    var d = new Date();
    return String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0');
  }

  function add(kind, nick, text) {
    var nearBottom = log.scrollHeight - log.scrollTop - log.clientHeight < 40;
    var li = document.createElement('li');
    li.className = 'is-' + kind + (nick && nick === me ? ' is-self' : '');
    var t = document.createElement('span');
    t.className = 'chat__time';
    t.textContent = hhmm();
    li.appendChild(t);
    if (nick && kind !== 'event') {
      var n = document.createElement('span');
      n.className = 'chat__nick';
      n.textContent = kind === 'action' ? '* ' + nick : '<' + nick + '>';
      li.appendChild(n);
    }
    li.appendChild(document.createTextNode(stripFormatting(text)));
    log.appendChild(li);
    while (log.children.length > MAX_LINES) log.removeChild(log.firstChild);
    if (nearBottom || nick === me) log.scrollTop = log.scrollHeight;
  }

  // ------------------------------------------------------------ connection

  function connect() {
    clearTimeout(retryTimer);
    leaving = false;
    joined = false;
    setStatus('Conectando…');
    try {
      ws = new WebSocket(URL_, 'text.ircv3.net');
    } catch (e) {
      setStatus('No se pudo abrir el chat.', 'error');
      return;
    }
    ws.onopen = function () {
      me = wanted;
      send('NICK ' + wanted);
      send('USER ' + wanted + ' 0 * :iScream');
    };
    ws.onmessage = function (ev) {
      if (typeof ev.data === 'string') ev.data.split(/\r?\n/).forEach(function (l) { if (l) handle(parse(l)); });
    };
    ws.onclose = function () {
      ws = null;
      if (leaving) return;
      if (joined) add('event', '', 'Se perdió la conexión con el chat.');
      joined = false;
      var wait = Math.min(30, Math.pow(2, retry++)) * 1000;
      setStatus('Sin conexión. Reintentando en ' + wait / 1000 + ' s…', 'error');
      retryTimer = setTimeout(connect, wait);
    };
  }

  function handle(m) {
    var p = m.params;
    switch (m.command) {
      case 'PING':
        send('PONG :' + (p[0] || ''));
        break;
      case '001': // welcome: registration done
        me = p[0];
        retry = 0;
        send('JOIN ' + CHANNEL);
        break;
      case '433': // nickname in use
      case '432': // erroneous nickname
        if (!joined) {
          wanted = cleanNick(wanted.slice(0, 16) + Math.floor(10 + Math.random() * 90));
          send('NICK ' + wanted);
        } else {
          add('event', '', 'Ese apodo no está disponible.');
        }
        break;
      case 'JOIN':
        if (m.nick === me) {
          joined = true;
          setStatus('En ' + CHANNEL + ' como ' + me);
          add('event', '', 'Entraste a ' + CHANNEL + '. Aquí no queda historial: solo ves lo que se dice mientras estás.');
        } else {
          add('event', '', m.nick + ' entró');
        }
        break;
      case 'PART':
        add('event', '', m.nick + ' salió');
        break;
      case 'QUIT':
        add('event', '', m.nick + ' se desconectó');
        break;
      case 'NICK':
        if (m.nick === me) {
          me = p[0];
          wanted = me;
          store(NICK_KEY, me);
          setStatus('En ' + CHANNEL + ' como ' + me);
        }
        add('event', '', m.nick + ' ahora es ' + p[0]);
        break;
      case 'KICK':
        add('event', '', p[1] + ' fue expulsado por ' + m.nick + (p[2] ? ' (' + p[2] + ')' : ''));
        if (p[1] === me) { joined = false; setStatus('Te sacaron del canal.', 'error'); }
        break;
      case '332': // topic
        add('event', '', 'Tema: ' + (p[2] || ''));
        break;
      case '353': // names
        var count = (p[3] || '').split(' ').filter(Boolean).length;
        if (count) add('event', '', count + (count === 1 ? ' persona' : ' personas') + ' en el canal');
        break;
      case 'PRIVMSG':
      case 'NOTICE':
        var target = p[0];
        var text = p[1] || '';
        var action = /^\x01ACTION (.*)\x01?$/.exec(text);
        if (/^\x01/.test(text) && !action) break; // other CTCP: ignore
        if (target.toLowerCase() === CHANNEL) {
          add(action ? 'action' : 'msg', m.nick, action ? ' ' + action[1].replace(/\x01$/, '') : text);
        } else if (m.nick && m.nick.indexOf('.') === -1 && target === me) {
          add('msg', m.nick, '(privado) ' + text);
        }
        break;
      case 'ERROR':
        setStatus('El servidor cerró la conexión.', 'error');
        break;
      case '404': // cannot send to channel
      case '477':
      case '474':
      case '475':
      case '471':
      case '473':
        add('event', '', p[p.length - 1] || 'No se pudo.');
        break;
    }
  }

  // ------------------------------------------------------------ UI

  joinForm.addEventListener('submit', function (e) {
    e.preventDefault();
    wanted = cleanNick(nickInput.value);
    store(NICK_KEY, wanted);
    joinForm.hidden = true;
    chat.hidden = false;
    connect();
    input.focus();
  });

  sayForm.addEventListener('submit', function (e) {
    e.preventDefault();
    var text = input.value.trim();
    if (!text) return;
    if (!joined) {
      add('event', '', 'Todavía no estás en el canal.');
      return;
    }
    var cmd = /^\/(\w+)\s*(.*)$/.exec(text);
    if (cmd) {
      var name = cmd[1].toLowerCase();
      if (name === 'nick' && cmd[2]) send('NICK ' + cleanNick(cmd[2]));
      else if (name === 'me' && cmd[2]) {
        send('PRIVMSG ' + CHANNEL + ' :\x01ACTION ' + cmd[2] + '\x01');
        add('action', me, ' ' + cmd[2]);
      } else add('event', '', 'Comandos: /nick nuevo_apodo, /me acción');
    } else {
      send('PRIVMSG ' + CHANNEL + ' :' + text);
      add('msg', me, text);
    }
    input.value = '';
  });

  window.addEventListener('pagehide', function () {
    leaving = true;
    send('QUIT :chao');
  });

  var saved = store(NICK_KEY);
  if (saved) nickInput.value = saved;
})();
