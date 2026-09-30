(function(){
class FocusTrapManager {
  static #instance = null;
  
  // 登録された要素と、その要素用の AbortController を一元管理
  #registry = new WeakMap();
  
  // 直近でユーザーが操作していたコンテナ要素を弱参照で記憶（フォーカス救済用）
  #lastActiveContainerRef = null;

  constructor() {
    if (FocusTrapManager.#instance) {
      return FocusTrapManager.#instance;
    }
    FocusTrapManager.#instance = this;

    // 画面全体のフォーカス移動を一元監視
    this.#initFocusTracker();
  }

  static getInstance() {
    if (!FocusTrapManager.#instance) {
      FocusTrapManager.#instance = new FocusTrapManager();
    }
    return FocusTrapManager.#instance;
  }

  #initFocusTracker() {
    // 1. フォーカスが動くたびに、今どのコンテナにいるかを記憶
    document.body.addEventListener('focusin', (e) => {
      let current = e.target;
      while (current && current !== document.body) {
        if (this.#registry.has(current)) {
          this.#lastActiveContainerRef = new WeakRef(current);
          break;
        }
        current = current.parentElement;
      }
    });

    // 2. 要素が削除等されてフォーカスがbodyに戻った瞬間を検知して救済
    document.body.addEventListener('focusout', () => {
      setTimeout(() => {
        if (document.activeElement === document.body || document.activeElement === null) {
          this.#rescueFocus();
        }
      }, 0);
    });
  }

  #rescueFocus() {
    if (!this.#lastActiveContainerRef) return;

    const activeContainer = this.#lastActiveContainerRef.deref();
    
    // コンテナがまだDOMに実在しており、かつ「コンテナ自体が表示状態」のときのみ実行
    if (activeContainer && activeContainer.isConnected && this.#isElementVisible(activeContainer)) {
      const currentElements = this.#getFocusableElements(activeContainer);
      if (currentElements.length > 0) {
        currentElements[0].focus();
      }
    }
  }

  #isValidElement(el) {
    return el instanceof HTMLElement && el.isConnected;
  }

  /**
   * 各種非表示CSS（display, visibility, content-visibility）を厳格に判定する共通関数
   */
  #isElementVisible(el) {
    // 【修正】visibilityProperty: true を指定することで、visibility: hidden も確実に弾く
    return el.checkVisibility({ visibilityProperty: true });
  }

  /**
   * 対象エリア内のフォーカス可能な要素を厳格に抽出
   */
  #getFocusableElements(container) {
    // 【修正】コンテナ自体が content-visibility: hidden などで中身をスキップしている場合は即座に空配列を返す
    if (!this.#isElementVisible(container)) return [];

    const candidates = container.querySelectorAll(
      'button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])'
    );
    
    return Array.from(candidates).filter(el => {
      // 自身および親要素のすべての非表示状態、および disabled を厳格に判定
      return this.#isElementVisible(el) && !el.disabled;
    });
  }

  /**
   * 指定した要素に対してフォーカスループの管理を「登録」する
   */
  register(el) {
    if (!this.#isValidElement(el)) return;

    // すでに登録済みの場合は何もしない（多重登録の完全防止）
    if (this.#registry.has(el)) return;

    const controller = new AbortController();
    this.#registry.set(el, controller);

    // 最初のフォーカス移動（コンテナが表示されている場合のみ）
    const initialElements = this.#getFocusableElements(el);
    if (initialElements.length > 0) {
      initialElements[0].focus();
      this.#lastActiveContainerRef = new WeakRef(el);
    }

    // 対象要素に対してイベントをバインド
    el.addEventListener('keydown', (e) => {
      if (e.key !== 'Tab') return;

      const currentElements = this.#getFocusableElements(el);
      if (currentElements.length === 0) return;

      const firstElement = currentElements[0];
      const lastElement = currentElements[currentElements.length - 1];

      if (e.shiftKey) {
        if (document.activeElement === firstElement) {
          lastElement.focus();
          e.preventDefault();
        }
      } else {
        if (document.activeElement === lastElement) {
          firstElement.focus();
          e.preventDefault();
        }
      }
    }, { signal: controller.signal });
  }

  /**
   * 指定した要素のフォーカスループ管理を「解除」する
   */
  unregister(el) {
    if (!el) return;
    if (this.#registry.has(el)) {
      this.#registry.get(el).abort();
      this.#registry.delete(el);
      
      if (this.#lastActiveContainerRef && this.#lastActiveContainerRef.deref() === el) {
        this.#lastActiveContainerRef = null;
      }
    }
  }
}
globalThis.focusLooper = FocusTrapManager.getInstance();
})();

