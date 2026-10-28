// SupabaseConfig.swift
// GetNewWord
//
// 共用账号平台（Supabase 项目 blsbkqreuhgvksphsvaw）的公开连接信息。
// anon key 是公开的客户端 key（web 端同样随包下发），数据安全靠 RLS（auth.uid() = user_id）。

import Foundation

enum SupabaseConfig {
    static let url = URL(string: "https://blsbkqreuhgvksphsvaw.supabase.co")!
    static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImJsc2JrcXJldWhndmtzcGhzdmF3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQyMzkyMTcsImV4cCI6MjA5OTgxNTIxN30.9Ddh8LDraJYrSzjtJdDgMIUueDjzRdvEJXtLKOK7li8"
    /// GetNewWord 的表所在 schema（PostgREST 用 Accept-Profile / Content-Profile 头切换）
    static let schema = "getnewword"
}
