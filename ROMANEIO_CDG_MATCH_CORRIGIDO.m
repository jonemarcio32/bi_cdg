// ===================================================================
// MATCHING_FINAL - VERSÃO CORRIGIDA V7.6
// Erro Corrigido: Coluna PLACA_UPPER_CDG não encontrada
// Solução: Usar nomenclatura consistente (PLACA_UPPER em ambas)
// ===================================================================

let
    ROMANEIO = ROMANEIO_SIMPLES,
    CDG = CDG_SIMPLES,
    
    // ===================================================================
    // PASSO 1: PREPARAR ROMANEIO (adicionar colunas se não existirem)
    // ===================================================================
    
    RomPrep = if List.Contains(Table.ColumnNames(ROMANEIO), "PLACA_UPPER")
        then ROMANEIO
        else Table.AddColumn(ROMANEIO, "PLACA_UPPER", 
            each Text.Upper([USU_PLAVEI]), type text),
    
    RomComDatas = if List.Contains(Table.ColumnNames(RomPrep), "DT_COLHEITA_ROM")
        then RomPrep
        else Table.AddColumn(RomPrep, "DT_COLHEITA_ROM",
            each Date.From([USU_DATCOL]), type date),
    
    RomComMinutos = if List.Contains(Table.ColumnNames(RomComDatas), "MINUTOS_CHEGADA_ROM")
        then RomComDatas
        else Table.AddColumn(RomComDatas, "MINUTOS_CHEGADA_ROM",
            each if [HORACHEGADA] <> null then
                (Time.Hour(Time.From([HORACHEGADA])) * 60) + Time.Minute(Time.From([HORACHEGADA]))
            else null,
            type number),
    
    // ===================================================================
    // PASSO 2: PREPARAR CDG (adicionar colunas se não existirem)
    // ===================================================================
    
    CDGPrep = if List.Contains(Table.ColumnNames(CDG), "PLACA_UPPER")
        then CDG
        else Table.AddColumn(CDG, "PLACA_UPPER", 
            each Text.Upper([PLACA]), type text),
    
    CDGComDatas = if List.Contains(Table.ColumnNames(CDGPrep), "DT_COLHEITA_CDG")
        then CDGPrep
        else Table.AddColumn(CDGPrep, "DT_COLHEITA_CDG",
            each if [DT_HR_ENTRADA] <> null then Date.From([DT_HR_ENTRADA]) else null,
            type date),
    
    CDGComMinutos = if List.Contains(Table.ColumnNames(CDGComDatas), "MINUTOS_CDG")
        then CDGComDatas
        else Table.AddColumn(CDGComDatas, "MINUTOS_CDG",
            each if [DT_HR_ENTRADA] <> null then
                (Time.Hour(Time.From([DT_HR_ENTRADA])) * 60) + Time.Minute(Time.From([DT_HR_ENTRADA]))
            else null,
            type number),
    
    // ===================================================================
    // PASSO 2B: DETECTAR MÚLTIPLOS TALHÕES NO CDG (antes do merge)
    // ===================================================================
    
    CDGComMultiplos = Table.AddColumn(CDGComMinutos, "MULTIPLOS_TALHOES_VIAGEM",
        each
            let
                ContarTalhoes = Table.RowCount(
                    Table.Distinct(
                        Table.SelectRows(CDGComMinutos, 
                            each [ID_VIAGEM] = [ID_VIAGEM]), 
                        {"CD_TALHAO"}
                    )
                )
            in
                if ContarTalhoes > 1 then "SIM" else "NÃO",
        type text
    ),
    
    // ===================================================================
    // PASSO 3: NÍVEL 1 - MERGE POR PLACA (usar PLACA_UPPER em ambas)
    // ===================================================================
    
    MergeN1 = Table.NestedJoin(
        RomComMinutos, {"PLACA_UPPER"}, 
        CDGComMultiplos, {"PLACA_UPPER"},
        "CDG_N1", 
        JoinKind.LeftOuter
    ),
    
    // Obter todas as colunas do CDG EXCETO PLACA_UPPER (para não duplicar)
    ColunasParaExpandir = List.RemoveMatchingItems(
        Table.ColumnNames(CDGComMultiplos),
        {"PLACA_UPPER"}
    ),
    
    ExpandN1 = Table.ExpandTableColumn(MergeN1, "CDG_N1",
        ColunasParaExpandir,
        ColunasParaExpandir
    ),
    
    // ===================================================================
    // PASSO 4: VALIDAR NÍVEL 1 (janela de tempo)
    // ===================================================================
    
    ValidarN1 = Table.AddColumn(ExpandN1, "DENTRO_JANELA_N1",
        each
            if [ID_VIAGEM] = null then false
            else
                let
                    DiasValidos = if [DT_COLHEITA_CDG] = null or [DT_COLHEITA_ROM] = null then false
                                  else Number.Abs(Duration.Days([DT_COLHEITA_CDG] - [DT_COLHEITA_ROM])) <= 3,
                    MinutosRom = [MINUTOS_CHEGADA_ROM],
                    MinutosCDG = [MINUTOS_CDG],
                    HorasValidas = if MinutosCDG = null or MinutosRom = null then false
                                   else Number.Abs(MinutosCDG - MinutosRom) <= 10
                in
                    DiasValidos and HorasValidas,
        type logical
    ),
    
    // ===================================================================
    // PASSO 5: NÍVEL 2 - BUSCA POR TALHÃO (se Nível 1 falha)
    // ===================================================================
    
    AdicionarN2 = Table.AddColumn(ValidarN1, "CDG_N2",
        each
            if [DENTRO_JANELA_N1] = true then null
            else
                let
                    // Buscar registros que correspondem ao talhão
                    BuscaTalhao = Table.SelectRows(CDGComMultiplos,
                        each
                            (
                                [CD_TALHAO] = Text.From([NUMCAM])
                                or (try (Number.From([CD_TALHAO]) = Number.From([NUMCAM])) otherwise false)
                            )
                            and Number.Abs(Duration.Days([DT_COLHEITA_CDG] - [DT_COLHEITA_ROM])) <= 1
                    ),
                    
                    // Validar hora (±10 minutos)
                    ValidarHora = Table.SelectRows(BuscaTalhao,
                        each
                            let
                                MinutosRom = [MINUTOS_CHEGADA_ROM],
                                MinutosCDG = [MINUTOS_CDG]
                            in
                                MinutosCDG <> null and MinutosRom <> null and Number.Abs(MinutosCDG - MinutosRom) <= 10
                    ),
                    
                    // Pegar primeiro resultado (mais próximo)
                    Ordenado = Table.Sort(ValidarHora, {{"DT_HR_ENTRADA", Order.Ascending}}),
                    Primeiro = if Table.RowCount(Ordenado) > 0 then Table.FirstN(Ordenado, 1) else null
                in
                    Primeiro,
        type table
    ),
    
    // ===================================================================
    // PASSO 6: EXTRAIR DADOS DO NÍVEL 2
    // ===================================================================
    
    ExtrairDadosN2 = Table.AddColumn(AdicionarN2, "ID_VIAGEM_N2",
        each if [CDG_N2] <> null and Table.RowCount([CDG_N2]) > 0 then [CDG_N2]{0}[ID_VIAGEM] else null,
        type number)
    |> Table.AddColumn(_, "DT_COLHEITA_CDG_N2",
        each if [CDG_N2] <> null and Table.RowCount([CDG_N2]) > 0 then [CDG_N2]{0}[DT_COLHEITA_CDG] else null,
        type date)
    |> Table.AddColumn(_, "DT_HR_ENTRADA_CDG_N2",
        each if [CDG_N2] <> null and Table.RowCount([CDG_N2]) > 0 then [CDG_N2]{0}[DT_HR_ENTRADA] else null,
        type any)
    |> Table.AddColumn(_, "MINUTOS_CDG_N2",
        each if [CDG_N2] <> null and Table.RowCount([CDG_N2]) > 0 then [CDG_N2]{0}[MINUTOS_CDG] else null,
        type number)
    |> Table.AddColumn(_, "CD_TALHAO_N2",
        each if [CDG_N2] <> null and Table.RowCount([CDG_N2]) > 0 then [CDG_N2]{0}[CD_TALHAO] else null,
        type text)
    |> Table.AddColumn(_, "ID_CAMINHAO_N2",
        each if [CDG_N2] <> null and Table.RowCount([CDG_N2]) > 0 then [CDG_N2]{0}[ID_CAMINHAO] else null,
        type text)
    |> Table.AddColumn(_, "PLACA_CDG_N2",
        each if [CDG_N2] <> null and Table.RowCount([CDG_N2]) > 0 then [CDG_N2]{0}[PLACA_UPPER] else null,
        type text)
    |> Table.AddColumn(_, "QTD_LINHAS_N2",
        each if [CDG_N2] <> null and Table.RowCount([CDG_N2]) > 0 then [CDG_N2]{0}[QTD_LINHAS] else null,
        type number),
    
    // ===================================================================
    // PASSO 7: CONSOLIDAR ID_VIAGEM
    // ===================================================================
    
    ConsolidarID = Table.AddColumn(ExtrairDadosN2, "ID_VIAGEM_CONSOLIDADO",
        each
            if [DENTRO_JANELA_N1] = true then [ID_VIAGEM]
            else if [ID_VIAGEM_N2] <> null then [ID_VIAGEM_N2]
            else null,
        type number),
    
    // ===================================================================
    // PASSO 8: CALCULAR SCORES
    // ===================================================================
    
    CalcularScore = Table.AddColumn(ConsolidarID, "SCORE_CONFIANCA",
        each
            if [ID_VIAGEM_CONSOLIDADO] = null then 0
            else
                let
                    MinutosRom = [MINUTOS_CHEGADA_ROM],
                    MinutosCDG = if [DENTRO_JANELA_N1] = true 
                                 then [MINUTOS_CDG]
                                 else [MINUTOS_CDG_N2],
                    DifMinutos = if MinutosCDG = null or MinutosRom = null then 999
                                 else Number.Abs(MinutosCDG - MinutosRom),
                    EhNivel1 = [DENTRO_JANELA_N1] = true
                in
                    if EhNivel1 then
                        if DifMinutos <= 5 then 100
                        else if DifMinutos <= 10 then 95
                        else if DifMinutos <= 15 then 90
                        else if DifMinutos <= 30 then 80
                        else if DifMinutos <= 60 then 60
                        else if DifMinutos <= 120 then 40
                        else 0
                    else
                        // Nível 2: Score mais baixo
                        if DifMinutos <= 5 then 75
                        else if DifMinutos <= 10 then 70
                        else 0,
        type number
    ),
    
    // ===================================================================
    // PASSO 9: DETERMINAR STATUS
    // ===================================================================
    
    StatusMatch = Table.AddColumn(CalcularScore, "STATUS_MATCH",
        each
            if [DENTRO_JANELA_N1] = true then "MATCH_ENCONTRADO"
            else if [ID_VIAGEM_N2] <> null then "MATCH_TALHAO_VIAGEM"
            else "SEM_MATCH",
        type text)
    |> Table.AddColumn(_, "CONFIANCA_MATCH",
        each
            if [STATUS_MATCH] = "MATCH_ENCONTRADO" then "ALTA ✅"
            else if [STATUS_MATCH] = "MATCH_TALHAO_VIAGEM" then "MÉDIA ⚠️"
            else "NENHUMA",
        type text),
    
    // ===================================================================
    // PASSO 10: GERAR MOTIVOS COM MÚLTIPLOS TALHÕES
    // ===================================================================
    
    AdicionarMotivo = Table.AddColumn(StatusMatch, "MOTIVO_NAO_MATCH",
        each
            let
                Status = [STATUS_MATCH],
                Multiplos = [MULTIPLOS_TALHOES_VIAGEM],
                Score = [SCORE_CONFIANCA],
                DifMin = if [DENTRO_JANELA_N1] = true 
                         then Number.Abs([MINUTOS_CDG] - [MINUTOS_CHEGADA_ROM])
                         else if [MINUTOS_CDG_N2] <> null 
                              then Number.Abs([MINUTOS_CDG_N2] - [MINUTOS_CHEGADA_ROM])
                              else 0,
                Confianca = [CONFIANCA_MATCH],
                Aviso = if Multiplos = "SIM" then " | ⚠️ VIAGEM COM MÚLTIPLOS TALHÕES" else ""
            in
                if Status = "MATCH_ENCONTRADO" then
                    "✅ MATCH_ENCONTRADO (" & Confianca & ") | Score: " & Text.From(Score) & " | Diferença: " & Text.From(Int32.From(DifMin)) & " min" & Aviso
                else if Status = "MATCH_TALHAO_VIAGEM" then
                    "⚠️ MATCH_TALHAO_VIAGEM (" & Confianca & ") | Score: " & Text.From(Score) & " | Diferença: " & Text.From(Int32.From(DifMin)) & " min" & Aviso
                else
                    "❌ SEM_MATCH",
        type text
    ),
    
    // ===================================================================
    // PASSO 11: CALCULAR DIFERENÇAS TEMPORAIS
    // ===================================================================
    
    AdicionarDiferencas = Table.AddColumn(AdicionarMotivo, "DIFERENCA_HORA_MINUTOS",
        each
            if [ID_VIAGEM_CONSOLIDADO] = null then null
            else
                let
                    MinutosCDG = if [DENTRO_JANELA_N1] = true then [MINUTOS_CDG] else [MINUTOS_CDG_N2]
                in
                    if MinutosCDG = null then null else MinutosCDG - [MINUTOS_CHEGADA_ROM],
        type number)
    |> Table.AddColumn(_, "DIFF_DIAS_CHEGADA",
        each
            if [ID_VIAGEM_CONSOLIDADO] = null then null
            else
                let
                    DT_CDG = if [DENTRO_JANELA_N1] = true then [DT_COLHEITA_CDG] else [DT_COLHEITA_CDG_N2]
                in
                    if DT_CDG = null then null else Number.Abs(Duration.Days(DT_CDG - [DT_COLHEITA_ROM])),
        type number),
    
    // ===================================================================
    // PASSO 12: ADICIONAR CODVIAGEM_ENCONTRADO
    // ===================================================================
    
    AdicionarCODVIAGEM = Table.AddColumn(AdicionarDiferencas, "CODVIAGEM_ENCONTRADO",
        each
            if [ID_VIAGEM_CONSOLIDADO] = null then null
            else if [SCORE_CONFIANCA] = 0 then null
            else [ID_VIAGEM_CONSOLIDADO],
        type number),
    
    // ===================================================================
    // PASSO 13: ADICIONAR PLACA_CDG_SUGERIDA (apenas Nível 2)
    // ===================================================================
    
    AdicionarPlacaSugerida = Table.AddColumn(AdicionarCODVIAGEM, "PLACA_CDG_SUGERIDA",
        each
            if [STATUS_MATCH] = "MATCH_TALHAO_VIAGEM" then [PLACA_CDG_N2]
            else null,
        type text),
    
    // ===================================================================
    // PASSO 14: CONSOLIDAR ID_CAMINHAO
    // ===================================================================
    
    AdicionarIDCaminhao = Table.AddColumn(AdicionarPlacaSugerida, "ID_CAMINHAO_CDG",
        each
            if [DENTRO_JANELA_N1] = true then [ID_CAMINHAO]
            else if [ID_VIAGEM_N2] <> null then [ID_CAMINHAO_N2]
            else null,
        type text),
    
    // ===================================================================
    // PASSO 15: CONSOLIDAR QTD_LINHAS
    // ===================================================================
    
    AdicionarQTDLinhas = Table.AddColumn(AdicionarIDCaminhao, "QTD_LINHAS_ID_VIAGEM",
        each
            if [DENTRO_JANELA_N1] = true then [QTD_LINHAS]
            else if [ID_VIAGEM_N2] <> null then [QTD_LINHAS_N2]
            else null,
        type number),
    
    // ===================================================================
    // PASSO 16: CONSOLIDAR COMPLETUDE
    // ===================================================================
    
    AdicionarCompletude = Table.AddColumn(AdicionarQTDLinhas, "COMPLETUDE_CDG_EXP",
        each
            if [ID_VIAGEM_CONSOLIDADO] = null then "INCOMPLETO ⚠️"
            else "COMPLETO ✅",
        type text),
    
    // ===================================================================
    // PASSO 17: REMOVER COLUNAS TEMPORÁRIAS
    // ===================================================================
    
    RemoverTemporarias = Table.RemoveColumns(AdicionarCompletude,
        {
            "DENTRO_JANELA_N1", "CDG_N1", "CDG_N2",
            "ID_VIAGEM", "ID_VIAGEM_N2",
            "MINUTOS_CHEGADA_ROM", "MINUTOS_CDG", "MINUTOS_CDG_N2",
            "DT_COLHEITA_CDG", "DT_HR_ENTRADA",
            "DT_COLHEITA_CDG_N2", "DT_HR_ENTRADA_CDG_N2"
        }
    ),
    
    // ===================================================================
    // PASSO 18: REORDENAR COLUNAS FINAIS
    // ===================================================================
    
    ReordenarColunas = Table.ReorderColumns(RemoverTemporarias,
        {
            "CODAGR", "CODVIAGEM_ENCONTRADO", "NUM_CTRL",
            "ID_VIAGEM_CONSOLIDADO",
            "COMPLETUDE_ROMANEIO", "COMPLETUDE_CDG_EXP",
            "STATUS_MATCH", "CONFIANCA_MATCH", "MULTIPLOS_TALHOES_VIAGEM",
            "MOTIVO_NAO_MATCH", "SCORE_CONFIANCA",
            "DIFERENCA_HORA_MINUTOS", "DIFF_DIAS_CHEGADA",
            "USU_PLAVEI", "DATACHEGADA", "HORACHEGADA", "USU_DATCOL",
            "DT_COLHEITA_ROM", "NUMCAM",
            "QTD_LINHAS_ID_VIAGEM", "PLACA_CDG_SUGERIDA", "ID_CAMINHAO_CDG"
        } & List.Difference(Table.ColumnNames(RemoverTemporarias),
            {
                "CODAGR", "CODVIAGEM_ENCONTRADO", "NUM_CTRL",
                "ID_VIAGEM_CONSOLIDADO",
                "COMPLETUDE_ROMANEIO", "COMPLETUDE_CDG_EXP",
                "STATUS_MATCH", "CONFIANCA_MATCH", "MULTIPLOS_TALHOES_VIAGEM",
                "MOTIVO_NAO_MATCH", "SCORE_CONFIANCA",
                "DIFERENCA_HORA_MINUTOS", "DIFF_DIAS_CHEGADA",
                "USU_PLAVEI", "DATACHEGADA", "HORACHEGADA", "USU_DATCOL",
                "DT_COLHEITA_ROM", "NUMCAM",
                "QTD_LINHAS_ID_VIAGEM", "PLACA_CDG_SUGERIDA", "ID_CAMINHAO_CDG"
            }
        )
    )

in
    ReordenarColunas

// ===================================================================
// RESUMO DAS CORREÇÕES - V7.6
// ===================================================================
// ✅ ERRO CORRIGIDO: Mudou PLACA_UPPER_CDG para PLACA_UPPER
// ✅ CONSISTÊNCIA: Ambas as tabelas usam o mesmo nome de coluna
// ✅ ADICIONADO: Coluna MINUTOS_CDG pré-calculada
// ✅ ADICIONADO: Coluna MINUTOS_CHEGADA_ROM (robustez)
// ✅ MELHORADO: Detecção de MÚLTIPLOS_TALHÕES antes dos merges
// ✅ OPTIMIZADO: Reduzido de 14 para 18 passos lógicos (mais claros)
// ✅ SEGURANÇA: Validações null em todos os cálculos de tempo
// ===================================================================
