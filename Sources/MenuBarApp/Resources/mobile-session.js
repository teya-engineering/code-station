    (() => {
      const pairingID = location.pathname.split('/').filter(Boolean).pop();
      const fragment = new URLSearchParams(location.hash.slice(1));
      const storageKey = `code-station-pairing-${pairingID}`;
      const scannedSecret = fragment.get('secret');
      if (scannedSecret) sessionStorage.setItem(storageKey, scannedSecret);
      const secret = scannedSecret || sessionStorage.getItem(storageKey);
      if (location.hash) history.replaceState(null, '', location.pathname);

      const find = id => document.querySelector(`#${id}`);
      const directoryScreen = find('directory');
      const sessionScreen = find('session');
      const listTitle = find('list-title');
      const listWhere = find('list-where');
      const listLight = find('list-light');
      const projects = find('projects');
      const back = find('back');
      const light = find('light');
      const title = find('title');
      const where = find('where');
      const state = find('state');
      const diff = find('diff');
      const failure = find('failure');
      const context = find('context');
      const meterFill = find('meter-fill');
      const stop = find('stop');
      const transcript = find('transcript');
      const queuedPanel = find('queued');
      const queuedHead = find('queued-head');
      const queuedList = find('queued-list');
      const bar = find('bar');
      const composer = find('composer');
      const prompt = find('prompt');
      const sendButton = find('send');
      const attachButton = find('attach');
      const fileInput = find('file-input');
      const pendingRow = find('pending');
      const toast = find('toast');
      let socket;
      let authenticated = false;
      let pairingEnded = false;
      // When a code expires with no other code out, the Mac stops listening, so no
      // message can come back to say the pairing ended. After this many attempts that
      // never reach the Mac, the page says a fresh code is likely needed, but it keeps
      // trying in case the Mac was only asleep.
      const unreachableAfter = 20;
      let failedAttempts = 0;
      let activeSessionID;
      const drafts = new Map();
      let conversation = 'main';
      const scopeLabel = 'All projects shared';
      let filter = 'all';
      let query = '';
      let infoSheet;
      let modal;
      let modalReturn;
      let design;
      let selectedDesignScreen;
      let denialDraft = '';
      let newDraft = '';
      let authenticationTimer;
      let reconnectTimer;
      let toastTimer;
      let sheet;
      let scrim;
      let ask;
      // Which screen is up. The Mac decides it: a list arrives, or a session does.
      let screen = 'directory';
      // The list as the Mac last described it, so the new-session sheet can name the
      // project it is about without asking for it again.
      let listing = { projects: [] };
      // Keep expansion and see-more choices while directory updates arrive.
      const sessionLimit = 4;
      const expandedProjects = new Set();
      const knownProjects = new Set();
      const unfolded = new Set();
      let creating = false;
      // Whether the ask has been put down. It survives an update to the ask itself, so a
      // sheet folded away does not spring back up when a tool result lands behind it.
      let collapsed = false;
      let denying = false;
      const answerState = new Map();
      const expandedTools = new Set();
      // The transcript this phone has drawn, so an update only has to carry what moved.
      const model = new Map();
      const nodes = new Map();
      let order = [];
      let queuedPrompts = [];
      let header = {};

      const element = (tag, className, text) => {
        const node = document.createElement(tag);
        if (className) node.className = className;
        if (text !== undefined) node.textContent = text;
        return node;
      };

      const button = (className, text, handler) => {
        const node = element('button', className, text);
        node.type = 'button';
        node.addEventListener('click', handler);
        return node;
      };

      const showError = message => {
        toast.textContent = message;
        toast.classList.add('visible');
        clearTimeout(toastTimer);
        toastTimer = setTimeout(() => toast.classList.remove('visible'), 4500);
      };

      // Every file rides inside one WebSocket message as base64, and the Mac refuses a
      // message over 25 MB. Photos are shrunk first, since a full-size phone photo is
      // several megabytes and the agent reads it no better than a 2000-pixel copy.
      const draftFiles = new Map();
      const maximumUploadBytes = 18 * 1024 * 1024;
      const largestImageSide = 2000;
      let files = [];
      let preparing = 0;

      const shrinkImage = async file => {
        if (!/^image\/(jpeg|png|webp|heic|heif)$/.test(file.type)) return file;
        try {
          const bitmap = await createImageBitmap(file);
          const scale = Math.min(1, largestImageSide / Math.max(bitmap.width, bitmap.height));
          // HEIC is always converted, since the agents cannot read it.
          if (scale === 1 && file.size < 1.5 * 1024 * 1024 && !/hei[cf]$/.test(file.type)) {
            bitmap.close();
            return file;
          }
          const canvas = document.createElement('canvas');
          canvas.width = Math.round(bitmap.width * scale);
          canvas.height = Math.round(bitmap.height * scale);
          canvas.getContext('2d').drawImage(bitmap, 0, 0, canvas.width, canvas.height);
          bitmap.close();
          const blob = await new Promise(resolve => canvas.toBlob(resolve, 'image/jpeg', .85));
          if (!blob) return file;
          const name = `${file.name.replace(/\.[^.]+$/, '') || 'photo'}.jpg`;
          return new File([blob], name, { type: 'image/jpeg' });
        } catch {
          return file;
        }
      };

      const base64 = blob => new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(String(reader.result).split(',')[1] || '');
        reader.onerror = () => reject(reader.error);
        reader.readAsDataURL(blob);
      });

      const addFiles = async picked => {
        if (!picked.length) return;
        preparing += 1;
        try {
          for (const original of picked) {
            const file = await shrinkImage(original);
            const total = files.reduce((sum, item) => sum + item.size, 0) + file.size;
            if (total > maximumUploadBytes) {
              showError(`${original.name || 'That file'} is too large to send. Files can add up to 18 MB.`);
              continue;
            }
            files.push({
              name: file.name || 'pasted-file',
              size: file.size,
              data: await base64(file),
              preview: file.type.startsWith('image/') ? URL.createObjectURL(file) : undefined,
            });
            renderFiles();
          }
        } catch {
          showError('That file could not be read.');
        } finally {
          preparing -= 1;
        }
      };

      const renderFiles = () => {
        pendingRow.replaceChildren(...files.map(file => {
          const chip = element('div', 'pending-file');
          if (file.preview) {
            const image = element('img');
            image.src = file.preview;
            image.alt = '';
            chip.append(image);
          } else {
            chip.append(element('span', 'file-mark', (file.name.split('.').pop() || 'file').slice(0, 4).toUpperCase()));
          }
          chip.append(element('span', 'pending-name', file.name));
          const remove = button('', '×', () => {
            if (file.preview) URL.revokeObjectURL(file.preview);
            files = files.filter(item => item !== file);
            renderFiles();
          });
          remove.setAttribute('aria-label', `Remove ${file.name}`);
          chip.append(remove);
          return chip;
        }));
        pendingRow.hidden = !files.length;
      };

      const send = command => {
        if (!authenticated || !socket || socket.readyState !== WebSocket.OPEN) {
          showError('The Mac is not connected.');
          return false;
        }
        socket.send(JSON.stringify({ sessionID: activeSessionID, conversation, ...command }));
        return true;
      };

      const remoteButton = (className, text, handler) => {
        const node = button(className, text, handler);
        node.classList.add('remote');
        node.disabled = !authenticated;
        return node;
      };

      const setConnected = live => {
        authenticated = live;
        const unreachable = !pairingEnded && failedAttempts >= unreachableAfter;
        if (live) { clearTimeout(toastTimer); toast.classList.remove('visible'); }
        document.querySelectorAll('.connection-label').forEach(node => {
          node.textContent = live ? 'Connected' : pairingEnded ? 'Pairing ended' : 'Disconnected';
        });
        for (const dot of [light, listLight]) dot.className = live ? 'light live' : 'light';
        find('offline').hidden = live;
        find('offline-title').textContent = pairingEnded ? 'Scan a fresh QR code'
          : unreachable ? "Can't reach your Mac" : 'Connection interrupted';
        find('offline-detail').textContent = pairingEnded
          ? 'This pairing is no longer available. Open phone sharing on your Mac and scan a fresh code. Your draft is kept here.'
          : unreachable
            ? 'A code ends once the phone has been away longer than Mobile settings on your Mac allow. If so, open phone sharing on your Mac and scan a fresh code. Your draft is kept here.'
            : 'Your sessions and draft are still here. Keep your Mac awake and both devices on the same Wi-Fi.';
        find('retry').hidden = pairingEnded;
        sendButton.disabled = !live;
        attachButton.disabled = !live;
        stop.disabled = !live;
        back.disabled = !live;
        find('discuss-design').disabled = !live;
        document.querySelectorAll('.remote').forEach(node => { node.disabled = !live; });
      };

      const dismissModal = () => {
        modal = undefined;
        directoryScreen.inert = false;
        sessionScreen.inert = false;
        if (modalReturn?.isConnected && !modalReturn.disabled && !modalReturn.closest('[hidden]')) modalReturn.focus();
        else (screen === 'directory' ? find('search') : ask ? bar : prompt).focus();
        modalReturn = undefined;
      };

      const focusDialog = (panel, label) => {
        if (!modal) modalReturn = document.activeElement;
        modal = panel;
        panel.setAttribute('aria-modal', 'true');
        panel.setAttribute('aria-label', label);
        panel.tabIndex = -1;
        directoryScreen.inert = true;
        sessionScreen.inert = true;
        panel.focus();
      };

      const closeInfo = () => {
        infoSheet?.remove();
        infoSheet = undefined;
        scrim?.remove();
        scrim = undefined;
        dismissModal();
        drawSheet();
      };

      const showInfo = (heading, lines) => {
        if (infoSheet) closeInfo();
        infoSheet = element('section', 'sheet');
        infoSheet.setAttribute('role', 'dialog');
        infoSheet.append(button('close', 'Close', closeInfo), element('h2', 'dialog-title', heading));
        for (const line of lines) infoSheet.append(element('p', 'dialog-copy', line));
        scrim = element('div');
        scrim.id = 'scrim';
        scrim.addEventListener('click', closeInfo);
        document.body.append(scrim, infoSheet);
        focusDialog(infoSheet, heading);
      };

      document.addEventListener('keydown', event => {
        if (!modal) {
          if (event.key === 'Escape' && document.body.classList.contains('design-expanded')) toggleExpand();
          return;
        }
        if (event.key === 'Escape') {
          event.preventDefault();
          if (infoSheet) closeInfo();
          else if (newSheet && !creating) closeNewSheet();
          else if (sheet) collapse(true);
        }
        if (event.key !== 'Tab' || !modal) return;
        const focusable = [...modal.querySelectorAll('button:not(:disabled), input:not(:disabled), textarea:not(:disabled), a[href]')]
          .filter(node => !node.hidden);
        const first = focusable[0], last = focusable.at(-1);
        if (!first) { event.preventDefault(); modal.focus(); }
        else if (event.shiftKey && (document.activeElement === first || document.activeElement === modal)) {
          event.preventDefault(); last.focus();
        } else if (!event.shiftKey && (document.activeElement === last || document.activeElement === modal)) {
          event.preventDefault(); first.focus();
        }
      });

      const show = next => {
        screen = next;
        directoryScreen.hidden = next !== 'directory';
        sessionScreen.hidden = next !== 'session';
        if (next !== 'session') showDesign(false);
      };

      // How long ago something happened, in the one or two characters the rows have room
      // for. Drawn here rather than sent, so an idle list costs nothing to keep current.
      const ago = when => {
        const seconds = Math.max(0, (Date.now() - Date.parse(when)) / 1000);
        if (seconds < 60) return 'Just now';
        if (seconds < 3600) return `${Math.floor(seconds / 60)} min ago`;
        if (seconds < 86400) return `${Math.floor(seconds / 3600)} hr ago`;
        if (seconds < 604800) return `${Math.floor(seconds / 86400)} days ago`;
        return `${Math.floor(seconds / 604800)} weeks ago`;
      };

      // MARK: - The list

      const sessionRow = session => {
        const row = remoteButton('row', '', () => send({ type: 'openSession', sessionID: session.id, conversation: session.conversation || 'main' }));
        row.type = 'button';
        const copy = element('div', 'row-copy');
        copy.append(element('div', 'row-title', session.title));
        const meta = element('div', 'row-meta');
        meta.append(element('span', '', ago(session.lastActivity)));
        meta.append(element('span', '', session.agent));
        if (session.workspace || session.branch) meta.append(element('span', '', session.workspace || session.branch));
        if (session.added || session.removed) {
          const changes = element('span', 'row-diff');
          changes.append(element('span', 'added', `+${session.added}`), element('span', 'removed', `−${session.removed}`));
          meta.append(changes);
        }
        copy.append(meta);
        row.append(copy);
        row.append(element('span', `row-state ${session.state === 'NEEDS YOU' ? 'wait' : session.state === 'RUNNING' ? 'run' : ''}`,
          session.state === 'NEEDS YOU' ? 'Needs you' : session.state === 'RUNNING' ? '● Running' : session.state === 'IDLE' ? 'Ready' : session.state.toLowerCase()));
        row.append(element('span', 'chevron', '›'));
        return row;
      };

      const projectGroup = project => {
        const expanded = !!query.trim() || filter !== 'all' || expandedProjects.has(project.id);
        const group = element('div', `group${expanded ? ' expanded' : ''}`);
        const head = element('div', 'group-head');
        const toggle = element('button', 'group-toggle');
        toggle.type = 'button';
        toggle.setAttribute('aria-expanded', String(expanded));
        const copy = element('div', 'group-copy');
        copy.append(element('div', 'group-name', project.name));
        copy.append(element('div', 'group-path',
          project.isMissing ? 'Missing from disk' : `${project.sessions.length} sessions`));
        const tile = element('span', 'project-tile', project.name.split(/[-_ ]/).map(part => part[0]).join('').slice(0, 2).toUpperCase());
        tile.style.setProperty('--tint', project.tint);
        tile.style.setProperty('--tint-ink', project.tintInk || 'var(--ink)');
        toggle.append(tile);
        toggle.append(copy);
        toggle.append(element('span', 'group-chevron', '›'));
        head.append(toggle);
        head.append(button('project-info', 'Project info', () => showInfo(project.name, [project.path,
          scopeLabel, 'You can read sessions, send instructions and respond to approval requests. Manage phone sharing on your Mac.'])));
        group.append(head);

        const body = element('div', 'group-body');
        const content = element('div', 'group-content');
        body.inert = !expanded;
        body.setAttribute('aria-hidden', String(!expanded));
        if (!project.sessions.length) {
          content.append(element('div', 'group-empty', 'No sessions yet'));
        }
        const visible = query.trim() || filter !== 'all' || unfolded.has(project.id)
          ? project.sessions
          : project.sessions.slice(0, sessionLimit);
        for (const session of visible) content.append(sessionRow(session));
        const hidden = project.sessions.length - visible.length;
        if (hidden) {
          content.append(button('more', `Show ${hidden} more`, () => {
            unfolded.add(project.id);
            renderDirectory(listing);
          }));
        }
        body.append(content);
        group.append(body);

        toggle.addEventListener('click', () => {
          const willExpand = !expandedProjects.has(project.id);
          if (willExpand) expandedProjects.add(project.id);
          else expandedProjects.delete(project.id);
          group.classList.toggle('expanded', willExpand);
          toggle.setAttribute('aria-expanded', String(willExpand));
          body.inert = !willExpand;
          body.setAttribute('aria-hidden', String(!willExpand));
        });
        return group;
      };

      const filteredProjects = (projects, filter, query) => {
        const needle = query.trim().toLocaleLowerCase();
        return projects.map(project => ({ ...project, sessions: project.sessions.filter(session =>
          (filter === 'all' || session.state === (filter === 'wait' ? 'NEEDS YOU' : 'RUNNING'))
          && [project.name, session.title, session.agent, session.branch || '', session.workspace || '']
            .join(' ').toLocaleLowerCase().includes(needle)) }))
          .filter(project => project.sessions.length || (!needle && filter === 'all'));
      };

      const renderDirectory = payload => {
        listing = payload;
        find('new-session').disabled = !authenticated || !payload.projects.some(project => !project.isMissing);
        listTitle.textContent = 'Code Station';
        const sessions = payload.projects.reduce((count, p) => count + p.sessions.length, 0);
        const running = payload.projects.reduce((count, p) =>
          count + p.sessions.filter(s => s.state === 'RUNNING').length, 0);
        const waiting = payload.projects.reduce((count, p) =>
          count + p.sessions.filter(s => s.state === 'NEEDS YOU').length, 0);
        listWhere.textContent = scopeLabel;
        document.title = 'Code Station';

        for (const project of payload.projects) {
          if (!knownProjects.has(project.id)) expandedProjects.add(project.id);
          knownProjects.add(project.id);
        }
        const counts = { all: sessions, wait: waiting, run: running };
        const labels = { all: 'All', wait: 'Needs you', run: 'Running' };
        document.querySelectorAll('[data-filter]').forEach(node => {
          node.textContent = `${labels[node.dataset.filter]} ${counts[node.dataset.filter]}`;
          node.classList.toggle('active', node.dataset.filter === filter);
          node.setAttribute('aria-pressed', String(node.dataset.filter === filter));
        });
        const attention = find('attention');
        attention.hidden = !waiting;
        const attentionCopy = element('div');
        attentionCopy.append(element('strong', '', `${waiting} session${waiting === 1 ? '' : 's'} need${waiting === 1 ? 's' : ''} you`),
          element('p', '', 'Open a session to see what needs you.'));
        attention.replaceChildren(attentionCopy, remoteButton('', 'Review', () => {
          const session = payload.projects.flatMap(project => project.sessions).find(session => session.state === 'NEEDS YOU');
          if (session) send({ type: 'openSession', sessionID: session.id, conversation: session.conversation || 'main' });
        }));
        const filtered = filteredProjects(payload.projects, filter, query);
        const groups = filtered.map(projectGroup);
        if (!groups.length) {
          const empty = element('div', 'empty', payload.projects.length ? 'No sessions found. Try another search or filter.' : 'There are no projects on this Mac yet.');
          if (query || filter !== 'all') empty.append(button('pill', 'Clear search and filters', () => {
            query = ''; filter = 'all'; find('search').value = ''; renderDirectory(listing); find('search').focus();
          }));
          groups.push(empty);
        }
        projects.replaceChildren(...groups);
        if (screen !== 'directory') show('directory');
        // The sheet names a project, and the project it named may be gone.
        if (newSheet) {
          const still = payload.projects.find(project => project.id === newProject.id);
          if (still) newProject = still;
          else closeNewSheet();
        }
      };

      // MARK: - Starting a session

      let newSheet;
      let newProject;
      let newWorktree = true;

      const openNewSheet = project => {
        newProject = project;
        newDraft = '';
        newWorktree = project.isGit;
        creating = false;
        drawNewSheet();
      };

      const closeNewSheet = () => {
        newSheet?.remove();
        newSheet = undefined;
        newProject = undefined;
        scrim?.remove();
        scrim = undefined;
        document.body.classList.remove('starting');
        dismissModal();
        drawSheet();
      };

      const drawNewSheet = () => {
        newSheet?.remove();
        scrim?.remove();
        document.body.classList.add('starting');
        scrim = element('div', '');
        scrim.id = 'scrim';
        scrim.addEventListener('click', () => { if (!creating) closeNewSheet(); });
        document.body.append(scrim);

        newSheet = element('div', 'sheet');
        newSheet.setAttribute('role', 'dialog');
        const handle = element('div', 'handle');
        newSheet.append(handle);
        newSheet.append(element('div', 'lead', `New session in ${newProject.name}`));

        const field = element('textarea');
        field.id = 'new-prompt';
        field.value = newDraft;
        field.addEventListener('input', () => { newDraft = field.value; });
        field.maxLength = 100000;
        field.placeholder = 'What should it do? (optional)';
        field.setAttribute('aria-label', 'First prompt');
        newSheet.append(field);

        // A plain folder has nothing to choose between, so the choice only appears where
        // it means something.
        if (newProject.isGit) {
          const options = element('div', 'options');
          const paint = () => {
            for (const node of options.children) {
              node.classList.toggle('chosen', node.dataset.worktree === String(newWorktree));
            }
          };
          const worktree = button('option', 'Its own worktree', () => {
            newWorktree = true;
            paint();
          });
          worktree.dataset.worktree = 'true';
          worktree.append(element('span', 'option-description',
            'An isolated checkout on a new branch, so it can run alongside the others.'));
          const folder = button('option', 'The project folder', () => {
            newWorktree = false;
            paint();
          });
          folder.dataset.worktree = 'false';
          folder.append(element('span', 'option-description',
            'Edits the working tree on your Mac directly.'));
          options.append(worktree, folder);
          newSheet.append(options);
          paint();
        }

        const buttons = element('div', 'buttons');
        buttons.append(button('quiet', 'Cancel', () => { if (!creating) closeNewSheet(); }));
        const create = remoteButton('allow', creating ? 'Starting…' : 'Create session', () => {
          if (creating) return;
          if (send({ type: 'createSession', projectID: newProject.id,
                     worktree: newWorktree, prompt: field.value.trim() })) {
            creating = true;
            create.textContent = 'Starting…';
            create.disabled = true;
          }
        });
        buttons.append(create);
        newSheet.append(buttons);
        document.body.append(newSheet);
        focusDialog(newSheet, `New session in ${newProject.name}`);
        dragToDismiss(handle, () => { if (!creating) closeNewSheet(); });
      };

      // MARK: - Status strip

      // "4M" while a turn runs, counting from when it was asked for; "2H" otherwise,
      // counting from the last thing that happened. Both are drawn here rather than sent,
      // so an idle session costs nothing to keep current.
      const elapsed = () => {
        if (!header.since) return '';
        const seconds = Math.max(0, (Date.now() - Date.parse(header.since)) / 1000);
        if (header.state === 'RUNNING') {
          if (seconds < 60) return `${Math.floor(seconds)}S`;
          if (seconds < 3600) return `${Math.floor(seconds / 60)} min ago`;
          if (seconds < 86400) return `${Math.floor(seconds / 3600)} hr ago`;
          return `${Math.floor(seconds / 86400)} days ago`;
        }
        return ago(header.since);
      };

      const renderElapsed = () => {
        if (!header.state) return;
        const queueStatus = header.queuedPrompts ? ` · ${header.queuedPrompts} QUEUED` : '';
        state.textContent = `${header.state} · ${elapsed()}${queueStatus}`;
      };

      const renderQueue = () => {
        queuedPanel.hidden = !queuedPrompts.length;
        if (!queuedPrompts.length) {
          queuedList.replaceChildren();
          return;
        }
        queuedHead.textContent = header.isBusy
          ? `QUEUED · ${queuedPrompts.length} · RUNS WHEN THIS TURN ENDS`
          : `QUEUED · ${queuedPrompts.length}`;
        queuedList.replaceChildren(...queuedPrompts.map(prompt => {
          const item = element('div', 'queued-item');
          if (prompt.text) item.append(element('div', 'queued-text', prompt.text));
          if (prompt.attachments?.length) {
            item.append(element('div', 'queued-attachments', prompt.attachments.join(' · ')));
          }
          return item;
        }));
      };

      const renderHeader = next => {
        header = next;
        title.textContent = next.title;
        where.textContent = next.branch ? `${next.project} · ${next.branch}`
                                        : `${next.project} · ${next.agent}`;
        document.title = `${next.title} · Code Station`;

        const running = next.state === 'RUNNING';
        light.className = authenticated ? 'light live' : 'light';
        state.className = running ? '' : next.state === 'IDLE' ? 'quiet' : 'attention';
        renderElapsed();
        renderQueue();

        failure.hidden = !next.failure;
        failure.textContent = next.failure || '';
        diff.hidden = !!next.failure || (!next.added && !next.removed);
        if (!diff.hidden) {
          diff.replaceChildren(element('span', 'added', `+${next.added}`),
                               element('span', 'removed', `−${next.removed}`));
        }
        context.hidden = next.context === null || next.context === undefined;
        if (!context.hidden) meterFill.style.width = `${Math.round(next.context * 100)}%`;
        stop.hidden = !next.isBusy;
      };

      // MARK: - Transcript

      const renderTool = tool => {
        const glyph = tool.isError ? '✕' : tool.isRunning ? '⋯' : '✓';
        const wrapper = element('div',
          `tool${tool.isError ? ' error' : tool.isRunning ? ' running' : ''}`);
        const row = element('button', 'tool-row');
        row.type = 'button';
        row.append(element('span', 'tool-glyph', glyph));
        row.append(element('span', 'tool-name', tool.name));
        row.append(element('span', 'tool-argument', tool.argument || ''));
        if (tool.added) row.append(element('span', 'tool-added', `+${tool.added}`));
        wrapper.append(row);

        // The row says what ran; what it said back is a tap away, so a long result never
        // takes the conversation over.
        const body = element('div', 'tool-body');
        body.hidden = !expandedTools.has(tool.id);
        if (tool.input) {
          body.append(element('div', 'tool-label', 'INPUT'));
          body.append(element('pre', '', tool.input));
        }
        if (tool.result) {
          body.append(element('div', 'tool-label', tool.isError ? 'ERROR' : 'RESULT'));
          body.append(element('pre', '', tool.result));
        }
        row.addEventListener('click', () => {
          body.hidden = !body.hidden;
          if (body.hidden) expandedTools.delete(tool.id);
          else expandedTools.add(tool.id);
        });
        wrapper.append(body);
        return wrapper;
      };

      // Fenced code stays source text on the phone, matching the transcript on the Mac.
      // The last segment may still be open while an answer streams, so an unmatched fence
      // is treated as code until its closing fence arrives.
      const fencedSegments = text => text.split('```').flatMap((part, index, parts) => {
        if (index % 2 === 0) {
          let prose = part;
          // The quote markers a fence opens on would draw as empty quote lines.
          if (index < parts.length - 1 && quoteDepth(part) > 0) {
            const lines = prose.split('\n');
            while (lines.length && /^[> \t]*$/.test(lines[lines.length - 1])) lines.pop();
            prose = lines.join('\n');
          }
          prose = prose.trim();
          return prose ? [{ kind: 'prose', text: prose }] : [];
        }

        let code = part;
        let language;
        const newline = part.indexOf('\n');
        if (newline >= 0) {
          const firstLine = part.slice(0, newline).trim();
          if (!firstLine || !firstLine.includes(' ')) {
            language = firstLine || undefined;
            code = part.slice(newline + 1);
          }
        }
        const depth = quoteDepth(parts[index - 1]);
        if (depth > 0) code = code.split('\n').map(line => unquoted(line, depth)).join('\n');
        code = code.replace(/^\n+|\n+$/g, '');
        // An empty suggestion is how a GitHub review comment asks to delete the lines.
        if (!code && (language !== 'suggestion' || index === parts.length - 1)) return [];
        return [{ kind: 'code', text: code, language }];
      });

      // A fence opened inside a quote sits on a line of bare quote markers, and every line
      // of its code starts with the same markers.
      const quoteDepth = text => {
        const line = text.slice(text.lastIndexOf('\n') + 1);
        return /^[>\s]*$/.test(line) ? (line.match(/>/g) || []).length : 0;
      };
      const unquoted = (line, depth) => {
        for (let level = 0; level < depth; level += 1) {
          const trimmed = line.replace(/^[ \t]*/, '');
          if (!trimmed.startsWith('>')) break;
          line = trimmed.slice(1);
        }
        return line.startsWith(' ') ? line.slice(1) : line;
      };

      // Inline marks are built as DOM nodes, never as HTML, so nothing an agent writes
      // can turn into markup on the page.
      const inlinePattern = /(`+)([\s\S]*?[^`])\1(?!`)|\*\*([\s\S]+?)\*\*|__([\s\S]+?)__|~~([\s\S]+?)~~|\*([^\s*](?:[\s\S]*?[^\s*])?)\*|(?<![\w])_([^\s_](?:[\s\S]*?[^\s_])?)_(?![\w])|\[([^\]\n]+)\]\(([^)\s]+)\)|(https?:\/\/[^\s<>()]*[^\s<>().,;:!?'"`])/g;

      const link = (label, href, labelNodes) => {
        if (!/^https?:\/\//i.test(href)) return document.createTextNode(label);
        const anchor = element('a', '');
        anchor.href = href;
        anchor.target = '_blank';
        anchor.rel = 'noopener noreferrer';
        anchor.append(...labelNodes);
        return anchor;
      };

      const wrapped = (tag, text) => {
        const node = element(tag, '');
        node.append(...inline(text));
        return node;
      };

      const inline = text => {
        const nodes = [];
        let last = 0;
        for (const match of text.matchAll(inlinePattern)) {
          if (match.index > last) nodes.push(document.createTextNode(text.slice(last, match.index)));
          const [, , code, strong, strongUnderscore, struck, em, emUnderscore, label, href, bare] = match;
          if (code !== undefined) {
            nodes.push(element('code', '', code.length > 2 && code.startsWith(' ') && code.endsWith(' ')
              ? code.slice(1, -1) : code));
          } else if (strong !== undefined || strongUnderscore !== undefined) {
            nodes.push(wrapped('strong', strong ?? strongUnderscore));
          } else if (struck !== undefined) nodes.push(wrapped('del', struck));
          else if (em !== undefined || emUnderscore !== undefined) nodes.push(wrapped('em', em ?? emUnderscore));
          else if (label !== undefined) nodes.push(link(label, href, inline(label)));
          else nodes.push(link(bare, bare, [document.createTextNode(bare)]));
          last = match.index + match[0].length;
        }
        if (last < text.length) nodes.push(document.createTextNode(text.slice(last)));
        return nodes;
      };

      const listItem = /^(\s*)([-*+]|\d{1,9}[.)])\s+(.*)$/;
      const isBlockStart = line => /^\s*(#{1,6}\s|>|([-*_]\s*){3,}$)/.test(line) || listItem.test(line);

      // Block marks a chat answer uses: headings, lists, quotes, rules and paragraphs.
      // A nested list follows its indent, so a sub-point sits inside its parent item.
      const markdownBlocks = text => {
        const blocks = [];
        const lines = text.split('\n');
        let index = 0;
        while (index < lines.length) {
          const line = lines[index];
          if (!line.trim()) {
            index += 1;
            continue;
          }
          const heading = line.match(/^\s*(#{1,6})\s+(.*?)\s*#*\s*$/);
          if (heading) {
            blocks.push(wrapped(`h${Math.min(heading[1].length + 2, 6)}`, heading[2]));
            index += 1;
            continue;
          }
          if (/^\s*([-*_]\s*){3,}$/.test(line)) {
            blocks.push(element('hr', ''));
            index += 1;
            continue;
          }
          if (/^\s*>/.test(line)) {
            const quoted = [];
            while (index < lines.length && /^\s*>/.test(lines[index])) {
              quoted.push(lines[index].replace(/^\s*> ?/, ''));
              index += 1;
            }
            const quote = element('blockquote', '');
            quote.append(...markdownBlocks(quoted.join('\n')));
            blocks.push(quote);
            continue;
          }
          if (listItem.test(line)) {
            const items = [];
            // Indented text after a blank line is a paragraph of the nearest item it sits
            // inside, so it lines up with that item's text instead of leaving the list.
            const owner = current => {
              const indent = current.match(/^\s*/)[0].length;
              if (indent < 2 || isBlockStart(current)) return null;
              return items.findLast(item => !item.paragraph && item.indent < indent) ?? null;
            };
            let afterBlank = false;
            while (index < lines.length) {
              const current = lines[index];
              const match = current.match(listItem);
              if (match) {
                const first = items[0];
                if (first && match[1].length <= first.indent
                  && /\d/.test(match[2]) !== /\d/.test(first.marker)) break;
                items.push({ indent: match[1].length, marker: match[2], lines: [match[3]] });
                afterBlank = false;
              } else if (!current.trim()) {
                const next = lines.slice(index + 1).find(next => next.trim());
                if (!next || !(listItem.test(next) || owner(next))) break;
                afterBlank = true;
              } else if (afterBlank && owner(current)) {
                items.push({ indent: owner(current).indent, paragraph: true, lines: [current.trim()] });
                afterBlank = false;
              } else if (!afterBlank && items.length && /^\s/.test(current) && !isBlockStart(current)) {
                items[items.length - 1].lines.push(current.trim());
              } else break;
              index += 1;
            }
            blocks.push(list(items));
            continue;
          }
          const paragraph = [];
          while (index < lines.length && lines[index].trim() && (!paragraph.length || !isBlockStart(lines[index]))) {
            paragraph.push(lines[index].trim());
            index += 1;
          }
          blocks.push(wrapped('p', paragraph.join('\n')));
        }
        return blocks;
      };

      const list = items => {
        const ordered = /\d/.test(items[0].marker);
        const node = element(ordered ? 'ol' : 'ul', '');
        if (ordered && parseInt(items[0].marker, 10) !== 1) node.start = parseInt(items[0].marker, 10);
        const base = items[0].indent;
        let index = 0;
        let entry = null;
        while (index < items.length) {
          const item = items[index];
          index += 1;
          if (item.paragraph) {
            entry.append(wrapped('p', item.lines.join('\n')));
            continue;
          }
          entry = wrapped('li', item.lines.join('\n'));
          const children = [];
          while (index < items.length && items[index].indent > base) {
            children.push(items[index]);
            index += 1;
          }
          if (children.length) entry.append(list(children));
          node.append(entry);
        }
        return node;
      };

      const renderProse = (text, showCursor) => {
        const prose = element('div', 'prose');
        for (const segment of fencedSegments(text)) {
          if (segment.kind === 'prose') {
            prose.append(...markdownBlocks(segment.text));
            continue;
          }
          const code = element('div', 'prose-code');
          if (segment.language) {
            code.append(element('div', 'code-language', segment.language.toUpperCase()));
          }
          code.append(segment.language === 'suggestion' && !segment.text
            ? element('div', 'code-deletion', 'Deletes the commented lines')
            : element('pre', '', segment.text));
          prose.append(code);
        }
        if (showCursor) {
          // The cursor trails the last words written, so it goes inside the deepest
          // closing block rather than on a line of its own below it.
          let tail = prose;
          while (tail.lastElementChild && /^(P|H\d|UL|OL|LI|BLOCKQUOTE)$/.test(tail.lastElementChild.tagName)) {
            tail = tail.lastElementChild;
          }
          tail.append(element('span', 'cursor'));
        }
        return prose;
      };

      // A person's turn is one tinted bubble; the agent's is plain prose with its calls
      // as rows of their own, which is the same shape the Mac draws.
      const renderMessage = (message, isLast) => {
        const wrapper = element('article', `message ${message.role}`);
        if (message.role === 'user') {
          if (message.text) wrapper.append(element('div', 'bubble', message.text));
        } else {
          const blocks = message.blocks || [];
          let lastProse = -1;
          for (let index = blocks.length - 1; index >= 0; index--) {
            if (blocks[index].kind === 'prose') {
              lastProse = index;
              break;
            }
          }
          for (const [index, block] of blocks.entries()) {
            if (block.kind === 'prose') {
              wrapper.append(renderProse(
                block.text || '',
                isLast && header.state === 'RUNNING' && index === lastProse));
            } else if (block.kind === 'thinking') {
              wrapper.append(element('div', 'thinking', block.text || ''));
            } else if (block.kind === 'tools') {
              for (const tool of block.tools || []) wrapper.append(renderTool(tool));
            }
          }
        }
        for (const attachment of message.attachments || []) {
          wrapper.append(element('span', 'attachment', attachment));
        }
        return wrapper;
      };

      const atBottom = () => transcript.scrollHeight - transcript.scrollTop
        - transcript.clientHeight < 180;

      const keepAtBottom = wasAtBottom => {
        if (wasAtBottom) requestAnimationFrame(() => { transcript.scrollTop = transcript.scrollHeight; });
      };

      // The order the Mac sent is the authority on layout. Moving nodes that already exist
      // keeps whatever the reader had opened or scrolled inside them.
      const place = () => {
        const wanted = new Set(order);
        for (const id of [...nodes.keys()]) {
          if (!wanted.has(id)) {
            nodes.get(id).remove();
            nodes.delete(id);
          }
        }
        for (const id of [...model.keys()]) if (!wanted.has(id)) model.delete(id);
        const rows = order.map((id, index) => {
          let node = nodes.get(id);
          if (!node) {
            node = renderMessage(model.get(id), index === order.length - 1);
            nodes.set(id, node);
          }
          return node;
        });
        if (header.hasEarlierMessages) {
          rows.unshift(element('div', 'notice', 'EARLIER MESSAGES ARE ON THE MAC'));
        }
        if (!rows.length) rows.push(element('div', 'empty', 'This session has no messages yet.'));
        transcript.replaceChildren(...rows);
      };

      const redrawMessage = id => {
        const existing = nodes.get(id);
        const fresh = renderMessage(model.get(id), order[order.length - 1] === id);
        nodes.set(id, fresh);
        if (existing && existing.parentNode) {
          existing.replaceWith(fresh);
          return true;
        }
        return false;
      };

      const applySnapshot = snapshot => {
        // A snapshot is also the answer to "start a session": it lands on the new one.
        if (newSheet) {
          creating = false;
          closeNewSheet();
        }
        if (activeSessionID !== snapshot.sessionID) {
          design = undefined;
          selectedDesignScreen = undefined;
          renderDesign();
          showDesign(false);
        }
        if (activeSessionID) {
          drafts.set(`${activeSessionID}:${conversation}`, prompt.value);
          draftFiles.set(`${activeSessionID}:${conversation}`, files);
        }
        activeSessionID = snapshot.sessionID;
        conversation = snapshot.conversation || 'main';
        prompt.value = drafts.get(`${activeSessionID}:${conversation}`) || '';
        files = draftFiles.get(`${activeSessionID}:${conversation}`) || [];
        renderFiles();
        prompt.style.height = '';
        find('conversation-tab').textContent = conversation === 'design' ? 'Conversation (back to main)' : 'Conversation';
        find('conversation-target').hidden = conversation !== 'design';
        find('conversation-target').textContent = 'Design conversation · Messages go to the companion Design session';
        prompt.setAttribute('aria-label', conversation === 'design' ? 'Message the Design conversation' : 'Message this session');
        prompt.placeholder = conversation === 'design' ? 'Message the Design conversation…' : 'Message this session…';
        queuedPrompts = snapshot.queued || [];
        renderHeader(snapshot.header);
        model.clear();
        nodes.clear();
        order = snapshot.messages.map(message => message.id);
        for (const message of snapshot.messages) model.set(message.id, message);
        place();
        renderAsk(snapshot.permission);
        if (screen !== 'session') show('session');
        keepAtBottom(true);
      };

      const applyUpdate = update => {
        const wasAtBottom = atBottom();
        const wasRunning = header.state === 'RUNNING';
        const queueChanged = update.queued !== undefined;
        if (queueChanged) queuedPrompts = update.queued || [];
        if (update.header) renderHeader(update.header);
        else if (queueChanged) renderQueue();
        let restructured = false;
        if (update.order) {
          order = update.order;
          restructured = true;
        }
        // The cursor rides the last answer, so a turn starting or ending has to redraw it
        // even when the transcript itself did not move.
        if (!restructured && wasRunning !== (header.state === 'RUNNING') && order.length) {
          redrawMessage(order[order.length - 1]);
        }

        const redraw = new Set();
        const appended = new Set();
        for (const change of update.changed || []) {
          if (change.kind === 'full') {
            model.set(change.id, {
              id: change.id,
              role: change.role,
              date: change.date,
              text: change.text || '',
              attachments: change.attachments || [],
              blocks: change.blocks || [],
            });
            redraw.add(change.id);
            continue;
          }
          const message = model.get(change.id);
          // A patch for a message this phone never drew means the two views have drifted
          // apart, and only the Mac can say what the truth is.
          if (!message) {
            send({ type: 'resync' });
            return;
          }
          if (change.textAppend) {
            message.text += change.textAppend;
            const prose = [...message.blocks].reverse().find(block => block.kind === 'prose');
            if (!prose) {
              send({ type: 'resync' });
              return;
            }
            prose.text = (prose.text || '') + change.textAppend;
          }
          for (const tool of change.tools || []) {
            const block = message.blocks.find(candidate =>
              candidate.kind === 'tools'
                && (candidate.tools || []).some(existing => existing.id === tool.id));
            if (!block) {
              send({ type: 'resync' });
              return;
            }
            const at = block.tools.findIndex(existing => existing.id === tool.id);
            block.tools[at] = tool;
            redraw.add(change.id);
          }
          if (change.textAppend && !redraw.has(change.id)) {
            appended.add(change.id);
          }
        }

        for (const id of redraw) if (!redrawMessage(id)) restructured = true;
        if (restructured) place();

        // Only the prose that grew is rebuilt, which keeps a long answer from rebuilding
        // its whole message, tool rows and all, on every chunk that arrives. A chunk can
        // close a mark opened in an earlier one, so the prose is parsed again as a whole.
        for (const id of appended) {
          const node = nodes.get(id);
          if (!node) continue;
          const proseBlocks = node.querySelectorAll('.prose');
          const prose = proseBlocks[proseBlocks.length - 1];
          if (prose) {
            const block = [...(model.get(id)?.blocks || [])].reverse()
              .find(candidate => candidate.kind === 'prose');
            prose.replaceWith(renderProse(block?.text || '', !!prose.querySelector('.cursor')));
            continue;
          }
          redrawMessage(id);
        }

        if (update.permissionCleared) renderAsk(undefined);
        else if (update.permission) renderAsk(update.permission);
        keepAtBottom(wasAtBottom);
      };

      // MARK: - The ask

      const answerFor = question => {
        const saved = answerState.get(question.text) || { choices: new Set(), other: '' };
        const typed = saved.other.trim();
        if (typed) return typed;
        return question.options
          .filter(option => saved.choices.has(option.label))
          .map(option => option.label)
          .join(', ');
      };

      const questionBody = () => {
        const submit = remoteButton('allow', 'Submit answers', () => {
          const answers = {};
          for (const question of ask.questions) answers[question.text] = answerFor(question);
          if (send({ type: 'answerPermission', requestID: ask.id, answer: 'answers', answers })) {
            submit.disabled = true;
          }
        });
        const readySubmit = () => {
          submit.disabled = !authenticated || !ask.questions.every(question => answerFor(question));
        };

        const parts = [];
        for (const question of ask.questions) {
          if (!answerState.has(question.text)) {
            answerState.set(question.text, { choices: new Set(), other: '' });
          }
          const saved = answerState.get(question.text);
          const options = element('div', 'options');
          const other = element('input', 'other');
          const paint = () => {
            for (const node of options.children) {
              node.classList.toggle('chosen', saved.choices.has(node.dataset.label));
            }
            readySubmit();
          };
          for (const option of question.options) {
            const choice = button('option', option.label, () => {
              saved.other = '';
              other.value = '';
              if (question.multiSelect) {
                if (saved.choices.has(option.label)) saved.choices.delete(option.label);
                else saved.choices.add(option.label);
              } else {
                const already = saved.choices.has(option.label);
                saved.choices.clear();
                if (!already) saved.choices.add(option.label);
              }
              paint();
            });
            choice.dataset.label = option.label;
            if (option.description) {
              choice.append(element('span', 'option-description', option.description));
            }
            options.append(choice);
          }
          other.placeholder = 'Something else…';
          other.value = saved.other;
          other.addEventListener('input', () => {
            saved.other = other.value;
            if (other.value) saved.choices.clear();
            paint();
          });
          parts.push(element('div', 'question-text', question.text), options, other);
          paint();
        }

        const buttons = element('div', 'buttons');
        buttons.append(remoteButton('deny', 'Skip', () =>
          send({ type: 'answerPermission', requestID: ask.id, answer: 'deny' })));
        buttons.append(submit);
        parts.push(buttons);
        return parts;
      };

      const permissionBody = () => {
        const parts = [];
        parts.push(element('h2', 'dialog-title', 'Allow this request?'));
        parts.push(element('div', 'dialog-copy', `${header.title} · ${header.project}`));
        parts.push(element('div', 'lead', ask.lead));
        if (ask.detail) parts.push(element('p', 'detail', ask.detail));
        if (ask.subject) parts.push(element('pre', 'subject', ask.subject));
        if (ask.runsIn) parts.push(element('div', 'runs-in', `Runs in ${ask.runsIn}`));

        const buttons = element('div', 'buttons');
        buttons.append(button('deny', 'Deny', () => {
          denying = true;
          drawSheet();
        }));
        buttons.append(remoteButton('allow', 'Allow once', () =>
          send({ type: 'answerPermission', requestID: ask.id, answer: 'allowOnce' })));
        parts.push(buttons);
        if (ask.alwaysTitle) {
          parts.push(remoteButton('always', ask.alwaysTitle, () =>
            send({ type: 'answerPermission', requestID: ask.id, answer: 'allowAlways' })));
        }
        return parts;
      };

      const denyBody = () => {
        const reason = element('div', 'reason');
        const field = element('textarea');
        field.placeholder = 'Tell the agent why…';
        field.value = denialDraft;
        field.addEventListener('input', () => { denialDraft = field.value; });
        field.maxLength = 100000;
        field.setAttribute('aria-label', 'Why this is denied');
        const submit = remoteButton('', '↑', () => {
          if (send({ type: 'answerPermission', requestID: ask.id, answer: 'deny',
                     prompt: field.value.trim() })) {
            submit.disabled = true;
          }
        });
        submit.setAttribute('aria-label', 'Send the denial');
        reason.append(field, submit);
        queueMicrotask(() => field.focus());
        return [element('div', 'lead', 'Why not?'), reason];
      };

      const drawSheet = () => {
        sheet?.remove();
        sheet = undefined;
        // The new-session sheet owns the scrim while it is up, so the ask leaves it alone.
        if (!newSheet && !infoSheet) {
          scrim?.remove();
          scrim = undefined;
        }
        document.body.classList.toggle('asking', !!ask && !collapsed);
        bar.hidden = !ask || !collapsed;
        if (!ask || newSheet || infoSheet) {
          if (!newSheet && !infoSheet && modal) dismissModal();
          return;
        }

        const label = ask.kind === 'question' ? 'QUESTION'
                                              : `PERMISSION · ${ask.toolName.toUpperCase()}`;
        if (collapsed) {
          if (modal) dismissModal();
          bar.replaceChildren(element('span', 'kind-dot'), element('span', '', label),
                              element('span', 'strip-gap'), element('span', 'open', 'OPEN'));
          return;
        }

        scrim = element('div', '');
        scrim.id = 'scrim';
        scrim.addEventListener('click', () => collapse(true));
        document.body.append(scrim);

        sheet = element('div', 'sheet');
        sheet.id = 'sheet';
        sheet.setAttribute('role', 'dialog');
        const handle = element('div', 'handle');
        sheet.append(handle);
        const kind = element('div', 'kind');
        kind.append(element('span', 'kind-dot'), element('span', 'kind-label', label));
        sheet.append(button('close', 'Close', () => collapse(true)), kind);
        const body = denying ? denyBody() : ask.kind === 'question' ? questionBody() : permissionBody();
        sheet.append(...body);
        document.body.append(sheet);
        focusDialog(sheet, ask.kind === 'question' ? 'Answer the agent' : 'Review permission');
        dragToDismiss(handle, () => collapse(true), sheet);
      };

      const renderAsk = request => {
        if (!request) {
          ask = undefined;
          collapsed = false;
          denying = false;
          answerState.clear();
          denialDraft = '';
          drawSheet();
          return;
        }
        if (ask?.id !== request.id) {
          collapsed = false;
          denying = false;
          answerState.clear();
          denialDraft = '';
        }
        ask = request;
        drawSheet();
      };

      const collapse = value => {
        if (!ask || collapsed === value) return;
        collapsed = value;
        drawSheet();
      };

      // Pulling the handle down puts a sheet away, which is the gesture the shape of a
      // sheet already promises.
      const dragToDismiss = (handle, dismiss, panel) => {
        let start;
        const moving = () => panel || newSheet;
        handle.addEventListener('pointerdown', event => {
          start = event.clientY;
          handle.setPointerCapture(event.pointerId);
        });
        handle.addEventListener('pointermove', event => {
          if (start === undefined) return;
          const travelled = event.clientY - start;
          if (travelled > 40) {
            start = undefined;
            if (moving()) moving().style.transform = '';
            dismiss();
          } else if (travelled > 0 && moving()) {
            moving().style.transform = `translateY(${travelled}px)`;
          }
        });
        const settle = () => {
          start = undefined;
          if (moving()) moving().style.transform = '';
        };
        handle.addEventListener('pointerup', settle);
        handle.addEventListener('pointercancel', settle);
      };

      // MARK: - Connection

      const connect = () => {
        clearTimeout(reconnectTimer);
        clearTimeout(authenticationTimer);
        if (pairingEnded) return;
        if (!secret) {
          pairingEnded = true;
          setConnected(false);
          return;
        }
        const previous = socket;
        socket = undefined;
        previous?.close();
        setConnected(false);
        document.querySelectorAll('.connection-label').forEach(node => { node.textContent = 'Connecting…'; });
        const scheme = location.protocol === 'https:' ? 'wss' : 'ws';
        const connection = new WebSocket(`${scheme}://${location.host}/socket/${pairingID}`);
        socket = connection;
        authenticationTimer = setTimeout(() => connection.close(), 10000);
        let reached = false;
        connection.addEventListener('open', () => {
          reached = true;
          failedAttempts = 0;
          connection.send(JSON.stringify({ type: 'authenticate', version: 1, secret }));
        });
        connection.addEventListener('message', event => {
          if (socket !== connection) return;
          try {
            const payload = JSON.parse(event.data);
            if (payload.type === 'snapshot' || payload.type === 'directory') {
              clearTimeout(authenticationTimer);
              if (!authenticated) setConnected(true);
              if (payload.type === 'snapshot') applySnapshot(payload);
              else renderDirectory(payload);
            } else if (payload.type === 'update' && authenticated) applyUpdate(payload);
            else if (payload.type === 'design' && authenticated && payload.sessionID === activeSessionID) {
              design = payload;
              renderDesign();
            } else if (payload.type === 'error') {
              if (payload.code === 'pairingEnded') {
                pairingEnded = true;
                clearTimeout(reconnectTimer);
                clearTimeout(authenticationTimer);
                setConnected(false);
                connection.close();
              } else showError(payload.message);
              if (creating) { creating = false; if (newSheet) drawNewSheet(); }
            }
          } catch (_) { showError('The Mac sent an unreadable update.'); }
        });
        connection.addEventListener('close', () => {
          if (socket !== connection) return;
          clearTimeout(authenticationTimer);
          if (!reached) failedAttempts += 1;
          setConnected(false);
          if (!pairingEnded) reconnectTimer = setTimeout(connect, 1500);
        });
        connection.addEventListener('error', () => connection.close());
      };

      const showDesign = visible => {
        document.body.classList.toggle('design-open', visible);
        if (!visible) {
          document.body.classList.remove('design-expanded');
          find('preview-expand').textContent = 'Expand';
          find('preview-expand').setAttribute('aria-pressed', 'false');
        }
        find('design-panel').hidden = !visible;
        find('design-tab').setAttribute('aria-pressed', String(visible));
        find('conversation-tab').setAttribute('aria-pressed', String(!visible));
        if (visible && ask) collapse(true);
      };

      const renderDesign = () => {
        const screens = design?.screens || [];
        const selected = screens.find(screen => screen.id === selectedDesignScreen) || screens[0];
        selectedDesignScreen = selected?.id;
        find('design-title').textContent = selected?.title || 'Design preview';
        find('design-empty').hidden = !!selected;
        find('design-frame').hidden = !selected;
        find('discuss-design').hidden = !design?.hasConversation;
        find('design-screens').replaceChildren(...screens.map(screen => {
          const choice = button(`pill${screen.id === selected?.id ? ' active' : ''}`, screen.title, () => {
            selectedDesignScreen = screen.id; renderDesign();
          });
          choice.setAttribute('aria-pressed', String(screen.id === selected?.id));
          return choice;
        }));
        if (selected) {
          const url = `${selected.url}?revision=${encodeURIComponent(design.revision)}`;
          if (find('design-frame').getAttribute('src') !== url) find('design-frame').src = url;
        } else find('design-frame').removeAttribute('src');
      };

      const toggleExpand = () => {
        const expanded = document.body.classList.toggle('design-expanded');
        find('preview-expand').textContent = expanded ? 'Collapse' : 'Expand';
        find('preview-expand').setAttribute('aria-pressed', String(expanded));
      };
      find('preview-expand').addEventListener('click', toggleExpand);
      find('preview-size').addEventListener('click', () => {
        const wide = find('design-canvas').classList.toggle('wide');
        find('preview-size').textContent = wide ? '960 px' : '390 px';
      });
      find('design-tab').addEventListener('click', () => showDesign(true));
      find('design-back').addEventListener('click', () => { showDesign(false); find('conversation-tab').focus(); });
      find('conversation-tab').addEventListener('click', () => {
        showDesign(false);
        if (conversation !== 'main') send({ type: 'openConversation', conversation: 'main' });
      });
      find('discuss-design').addEventListener('click', () => {
        if (send({ type: 'openConversation', conversation: 'design' })) showDesign(false);
      });
      find('retry').addEventListener('click', connect);
      find('new-session').addEventListener('click', () => {
        const available = listing.projects.filter(project => !project.isMissing);
        if (available.length === 1) { openNewSheet(available[0]); return; }
        showInfo('New session', ['Choose the project to work in.']);
        for (const project of available) {
          infoSheet.append(remoteButton('pill', project.name, () => { closeInfo(); openNewSheet(project); }));
        }
      });
      document.querySelectorAll('.connection').forEach(node => node.addEventListener('click', () =>
        showInfo(authenticated ? 'Connected to your Mac' : 'Connection unavailable', [authenticated ? scopeLabel : 'Waiting for authentication.',
          'Keep your Mac awake and both devices on the same trusted Wi-Fi.',
          pairingEnded ? 'Scan a fresh code from phone sharing on your Mac.' : 'Sessions run on your Mac. Your draft stays here if the connection drops.'])));
      document.querySelectorAll('[data-filter]').forEach(node => node.addEventListener('click', () => {
        filter = node.dataset.filter; renderDirectory(listing);
      }));
      find('search').addEventListener('input', event => { query = event.target.value; renderDirectory(listing); });

      composer.addEventListener('submit', event => {
        event.preventDefault();
        const text = prompt.value.trim();
        if (preparing) { showError('Still reading the attached files.'); return; }
        if (!text && !files.length) return;
        const attachments = files.map(({ name, data }) => ({ name, data }));
        if (send({ type: 'sendPrompt', prompt: text, attachments })) {
          prompt.value = '';
          prompt.style.height = '';
          files.forEach(file => file.preview && URL.revokeObjectURL(file.preview));
          files = [];
          renderFiles();
        }
      });
      attachButton.addEventListener('click', () => fileInput.click());
      fileInput.addEventListener('change', () => {
        addFiles([...fileInput.files]);
        fileInput.value = '';
      });
      // A screenshot copied on the phone arrives as a file on the paste, with no text.
      prompt.addEventListener('paste', event => {
        const pasted = [...(event.clipboardData?.files || [])];
        if (!pasted.length) return;
        event.preventDefault();
        addFiles(pasted);
      });
      prompt.addEventListener('input', () => {
        prompt.style.height = 'auto';
        prompt.style.height = `${Math.min(prompt.scrollHeight, 140)}px`;
      });
      stop.addEventListener('click', () => send({ type: 'stopTurn' }));
      back.addEventListener('click', () => {
        if (send({ type: 'closeSession' })) renderAsk(undefined);
      });
      bar.addEventListener('click', () => collapse(false));
      setInterval(renderElapsed, 15000);
      setConnected(false);
      show('directory');
      connect();
    })();
