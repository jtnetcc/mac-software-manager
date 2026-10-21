from __future__ import annotations


class MacappError(Exception):
    """可预期的用户级错误，CLI 捕获后只打印消息，不打印堆栈。"""

    def __init__(self, message: str, code: int = 1):
        super().__init__(message)
        self.message = message
        self.code = code


class SafetyError(MacappError):
    """路径校验未通过。"""

    def __init__(self, message: str, path: str = ""):
        super().__init__(message, code=3)
        self.path = path
