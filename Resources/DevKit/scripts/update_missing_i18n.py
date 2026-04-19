#!/usr/bin/env python3
"""
Update missing i18n translations in Localizable.xcstrings.
This script adds missing English localizations and fixes 'new' state translations.
"""

import sys

from i18n_tools import (
    DEFAULT_KEEP_LANGUAGES,
    default_file_path,
    load_strings,
    print_update_summary,
    save_strings,
    update_missing_translations,
)

# Populate this map with explicit translations when introducing new keys.
# Format: {"Key": {"zh-Hans": "示例", "es": "Ejemplo"}}
NEW_STRINGS: dict[str, dict[str, str]] = {
    "Codex Format": {
        "de": "Codex-Format",
        "es": "Formato Codex",
        "fr": "Format Codex",
        "ja": "Codex 形式",
        "ko": "Codex 형식",
        "zh-Hans": "Codex 格式",
    },
    "Reasoning Effort": {
        "de": "Reasoning-Aufwand",
        "es": "Esfuerzo de razonamiento",
        "fr": "Effort de raisonnement",
        "ja": "推論の労力",
        "ko": "추론 노력",
        "zh-Hans": "推理强度",
    },
    "Use ChatGPT Codex-compatible response format.": {
        "de": "Verwende ein mit ChatGPT Codex kompatibles Antwortformat.",
        "es": "Usa un formato de respuesta compatible con ChatGPT Codex.",
        "fr": "Utiliser un format de réponse compatible avec ChatGPT Codex.",
        "ja": "ChatGPT Codex 互換のレスポンス形式を使用します。",
        "ko": "ChatGPT Codex와 호환되는 응답 형식을 사용합니다.",
        "zh-Hans": "使用与 ChatGPT Codex 兼容的响应格式。",
    },
    "ChatGPT OAuth Session": {
        "de": "ChatGPT-OAuth-Sitzung",
        "es": "Sesión OAuth de ChatGPT",
        "fr": "Session OAuth ChatGPT",
        "ja": "ChatGPT OAuth セッション",
        "ko": "ChatGPT OAuth 세션",
        "zh-Hans": "ChatGPT OAuth 会话",
    },
    "FlowDown refreshes and applies ChatGPT OAuth credentials automatically for this endpoint.": {
        "de": "FlowDown aktualisiert ChatGPT-OAuth-Anmeldedaten für diesen Endpunkt automatisch und wendet sie an.",
        "es": "FlowDown actualiza y aplica automáticamente las credenciales OAuth de ChatGPT para este endpoint.",
        "fr": "FlowDown actualise et applique automatiquement les identifiants OAuth ChatGPT pour ce point de terminaison.",
        "ja": "FlowDown はこのエンドポイント向けに ChatGPT OAuth 認証情報を自動で更新し、適用します。",
        "ko": "FlowDown는 이 엔드포인트에 대해 ChatGPT OAuth 자격 증명을 자동으로 갱신하고 적용합니다.",
        "zh-Hans": "FlowDown 会为这个端点自动刷新并应用 ChatGPT OAuth 凭证。",
    },
    "Sign In to ChatGPT": {
        "de": "Bei ChatGPT anmelden",
        "es": "Iniciar sesión en ChatGPT",
        "fr": "Se connecter à ChatGPT",
        "ja": "ChatGPT にサインイン",
        "ko": "ChatGPT에 로그인",
        "zh-Hans": "登录 ChatGPT",
    },
    "Reconnect ChatGPT": {
        "de": "ChatGPT erneut verbinden",
        "es": "Reconectar ChatGPT",
        "fr": "Reconnecter ChatGPT",
        "ja": "ChatGPT を再接続",
        "ko": "ChatGPT 다시 연결",
        "zh-Hans": "重新连接 ChatGPT",
    },
    "Disconnect ChatGPT": {
        "de": "ChatGPT trennen",
        "es": "Desconectar ChatGPT",
        "fr": "Déconnecter ChatGPT",
        "ja": "ChatGPT の接続を解除",
        "ko": "ChatGPT 연결 해제",
        "zh-Hans": "断开 ChatGPT",
    },
    "Awaiting Redirect URL": {
        "de": "Warte auf Redirect-URL",
        "es": "Esperando URL de redirección",
        "fr": "URL de redirection en attente",
        "ja": "リダイレクト URL を待機中",
        "ko": "리디렉션 URL 대기 중",
        "zh-Hans": "等待重定向 URL",
    },
    "Paste Redirect URL": {
        "de": "Redirect-URL einfügen",
        "es": "Pegar URL de redirección",
        "fr": "Coller l'URL de redirection",
        "ja": "リダイレクト URL を貼り付け",
        "ko": "리디렉션 URL 붙여넣기",
        "zh-Hans": "粘贴重定向 URL",
    },
    "After ChatGPT finishes signing in, copy the full redirected URL and paste it here to complete OAuth.": {
        "de": "Nachdem du dich bei ChatGPT angemeldet hast, kopiere die vollständige Weiterleitungs-URL und füge sie hier ein, um OAuth abzuschließen.",
        "es": "Después de iniciar sesión en ChatGPT, copia la URL completa de redirección y pégala aquí para completar OAuth.",
        "fr": "Après la connexion à ChatGPT, copie l'URL complète de redirection et colle-la ici pour terminer OAuth.",
        "ja": "ChatGPT へのサインインが完了したら、完全なリダイレクト URL をコピーしてここに貼り付け、OAuth を完了してください。",
        "ko": "ChatGPT 로그인이 끝나면 전체 리디렉션 URL을 복사해 여기에 붙여넣어 OAuth를 완료하세요.",
        "zh-Hans": "完成 ChatGPT 登录后，复制完整的重定向 URL 并粘贴到这里，以完成 OAuth。",
    },
    "Complete Sign In": {
        "de": "Anmeldung abschließen",
        "es": "Completar inicio de sesión",
        "fr": "Terminer la connexion",
        "ja": "サインインを完了",
        "ko": "로그인 완료",
        "zh-Hans": "完成登录",
    },
    "Cancel Sign In": {
        "de": "Anmeldung abbrechen",
        "es": "Cancelar inicio de sesión",
        "fr": "Annuler la connexion",
        "ja": "サインインをキャンセル",
        "ko": "로그인 취소",
        "zh-Hans": "取消登录",
    },
    "Recommended": {
        "de": "Empfohlen",
        "es": "Recomendado",
        "fr": "Recommandé",
        "ja": "おすすめ",
        "ko": "추천",
        "zh-Hans": "推荐",
    },
    "Edit Bearer Token (Optional)": {
        "de": "Bearer-Token bearbeiten (optional)",
        "es": "Editar token Bearer (opcional)",
        "fr": "Modifier le jeton Bearer (optionnel)",
        "ja": "Bearer トークンを編集（任意）",
        "ko": "Bearer 토큰 편집(선택 사항)",
        "zh-Hans": "编辑 Bearer Token（可选）",
    },
    "When provided, FlowDown sends this value as Authorization: Bearer <token>. Leave it empty when your endpoint uses custom headers or anonymous access.": {
        "de": "Wenn ein Wert angegeben ist, sendet FlowDown ihn als Authorization: Bearer <token>. Lass das Feld leer, wenn dein Endpunkt benutzerdefinierte Header oder anonymen Zugriff verwendet.",
        "es": "Cuando se proporciona, FlowDown envía este valor como Authorization: Bearer <token>. Déjalo vacío si tu endpoint usa encabezados personalizados o acceso anónimo.",
        "fr": "Lorsqu'une valeur est fournie, FlowDown l'envoie comme Authorization: Bearer <token>. Laisse ce champ vide si ton point de terminaison utilise des en-têtes personnalisés ou un accès anonyme.",
        "ja": "値を入力すると、FlowDown はそれを Authorization: Bearer <token> として送信します。エンドポイントがカスタムヘッダーまたは匿名アクセスを使う場合は空のままにしてください。",
        "ko": "값을 입력하면 FlowDown가 이를 Authorization: Bearer <token>으로 전송합니다. 엔드포인트가 사용자 정의 헤더나 익명 액세스를 사용한다면 비워 두세요.",
        "zh-Hans": "填写后，FlowDown 会将这个值作为 Authorization: Bearer <token> 发送。你的端点如果使用自定义请求头或匿名访问，这里保持为空即可。",
    },
}

if __name__ == "__main__":
    file_path = sys.argv[1] if len(sys.argv) > 1 else default_file_path()

    data = load_strings(file_path)
    counts = update_missing_translations(
        data,
        new_strings=NEW_STRINGS,
        keep_languages=DEFAULT_KEEP_LANGUAGES,
    )
    save_strings(file_path, data)

    print_update_summary(file_path, counts)
