let
    ROMANEIO = ROMANEIO_SIMPLES,
    CDG = CDG_SIMPLES,

    // ===================================================================
    // PASSO 0: VALIDAÇÃO DE ENTRADA
    // ===================================================================

    #"ROMANEIO Validado" = Table.AddColumn(
        ROMANEIO,
        "VALIDACAO_ROMANEIO",
        each
            if [DATACHEGADA] = null then "ERRO_DATA_CHEGADA_NULL"
            else if [HORACHEGADA] = null then "ERRO_HORA_CHEGADA_NULL"
            else if [USU_PLAVEI] = null or [USU_PLAVEI] = "" then "ERRO_PLACA_NULL"
            else if [NUMCAM] = null then "ERRO_NUMCAM_NULL"
            else "OK"
        type text
    ),

    #"ROMANEIO com Flag Completude" = Table.AddColumn(
        #"ROMANEIO Validado",
        "COMPLETUDE_ROMANEIO",
        each if [VALIDACAO_ROMANEIO] <> "OK" then "INCOMPLETO ⚠️" else "COMPLETO ✅",
        type text
    ),

    #"CDG Validado" = Table.AddColumn(
        CDG,
        "VALIDACAO_CDG",
        each
            if [DT_HR_ENTRADA] = null then "ERRO_DT_ENTRADA_NULL"
            else if [PLACA] = null or [PLACA] = "" then "ERRO_PLACA_NULL"
            else "OK",
        type text
    ),

    #"CDG com Flag Completude" = Table.AddColumn(
        #"CDG Validado",
        "COMPLETUDE_CDG",
        each if [VALIDACAO_CDG] <> "OK" then "INCOMPLETO ⚠️" else "COMPLETO ✅",
        type text
    ),

    #"CDG com Data Chegada" = Table.AddColumn(
        #"CDG com Flag Completude",
        "DT_CHEGADA_CDG_CALC",
        each if [DT_HR_ENTRADA] <> null then Date.From([DT_HR_ENTRADA]) else null,
        type date
    ),

    // ===================================================================
    // PASSO 1: MERGE POR PLACA (NÍVEL 1)
    // ===================================================================

    #"Merge por Placa" = Table.NestedJoin(
        #"ROMANEIO com Flag Completude",
        {"PLACA_UPPER"},
        #"CDG com Data Chegada",
        {"PLACA"},
        "CDG_Matches_Nivel1",
        JoinKind.LeftOuter
    ),

    #"Expandir CDG Nível 1" = Table.ExpandTableColumn(
        #"Merge por Placa",
        "CDG_Matches_Nivel1",
        {
            "ID_VIAGEM", "DT_COLHEITA_CDG", "DT_HR_CAMPO", "DT_HR_ENTRADA", "QTD_LINHAS",
            "VALIDACAO_CDG", "COMPLETUDE_CDG", "DT_CHEGADA_CDG_CALC", "CD_TALHAO", "ID_CAMINHAO"
        },
        {
            "ID_VIAGEM_N1", "DT_COLHEITA_CDG_N1", "DT_HR_CAMPO_CDG_N1", "DT_HR_ENTRADA_CDG_N1",
            "QTD_LINHAS_N1", "VALIDACAO_CDG_N1", "COMPLETUDE_CDG_N1", "DT_CHEGADA_CDG_N1",
            "CD_TALHAO_N1", "ID_CAMINHAO_N1"
        }
    ),

    // ===================================================================
    // PASSO 1B: NÍVEL 2 - MATCH POR TALHÃO NA VIAGEM
    // Se placa não encontrou, busca por ID_VIAGEM que tem talhão correspondente
    // NOVO: Se ID_VIAGEM tem MÚLTIPLOS talhões, marca para observação
    // ===================================================================

    #"Tentar Match por Talhao Viagem" = Table.AddColumn(
        #"Expandir CDG Nível 1",
        "CDG_Matches_Nivel2",
        each
            if [ID_VIAGEM_N1] <> null then null  // Se já achou no nível 1, não tenta nível 2
            else
                let
                    RomData = [DATACHEGADA],
                    RomMinutos = [MINUTOS_CHEGADA_ROM],
                    RomNumCAM = [NUMCAM],
                    RomPlaca = [USU_PLAVEI]
                in
                    // Procurar no CDG registros que atendem:
                    // 1. Mesma data (±1 dia)
                    // 2. Hora ±10 minutos
                    // 3. ID_VIAGEM que tem registro com talhão = RomNumCAM
                    #"CDG com Data Chegada"
                    |> Table.SelectRows(each (
                        // Data similar
                        Number.Abs(Duration.Days(Date.From([DT_HR_ENTRADA]) - RomData)) <= 1
                        // Hora ±10 minutos
                        AND Number.Abs(
                            (Time.Hour(Time.From([DT_HR_ENTRADA])) * 60) +
                            Time.Minute(Time.From([DT_HR_ENTRADA])) -
                            RomMinutos
                        ) <= 10
                        // ⭐ NOVO: Talhão corresponde (NUMCAM = CD_TALHAO)
                        AND (try Number.From([CD_TALHAO]) = Number.From(RomNumCAM)
                             catch [CD_TALHAO] = Text.From(RomNumCAM))
                    ))
                    |> Table.Sort(each { [DT_HR_ENTRADA] })
                    |> Table.FirstN(1),
        type table
    ),

    #"Expandir CDG Nível 2" = Table.ExpandTableColumn(
        #"Tentar Match por Talhao Viagem",
        "CDG_Matches_Nivel2",
        {
            "ID_VIAGEM", "DT_COLHEITA_CDG", "DT_HR_CAMPO", "DT_HR_ENTRADA", "QTD_LINHAS",
            "VALIDACAO_CDG", "COMPLETUDE_CDG", "DT_CHEGADA_CDG_CALC", "CD_TALHAO", "ID_CAMINHAO", "PLACA"
        },
        {
            "ID_VIAGEM_N2", "DT_COLHEITA_CDG_N2", "DT_HR_CAMPO_CDG_N2", "DT_HR_ENTRADA_CDG_N2",
            "QTD_LINHAS_N2", "VALIDACAO_CDG_N2", "COMPLETUDE_CDG_N2", "DT_CHEGADA_CDG_N2",
            "CD_TALHAO_N2", "ID_CAMINHAO_N2", "PLACA_CDG_N2"
        }
    ),

    // ===================================================================
    // PASSO 1C: 🆕 VALIDAR MÚLTIPLOS TALHÕES NO ID_VIAGEM
    // Se encontrou match, contar quantos talhões tem naquele ID_VIAGEM
    // Se > 1, marcar FLAG para observação
    // ===================================================================

    #"Validar Multiplos Talhoes Viagem" = Table.AddColumn(
        #"Expandir CDG Nível 2",
        "MULTIPLOS_TALHOES_VIAGEM",
        each
            if [ID_VIAGEM_N1] <> null then
                // Nível 1 encontrou: contar talhões no ID_VIAGEM_N1
                let
                    IdViagemN1 = [ID_VIAGEM_N1],
                    TalhoesDiferentes =
                        #"CDG com Data Chegada"
                        |> Table.SelectRows(each [ID_VIAGEM] = IdViagemN1)
                        |> Table.Group(each [CD_TALHAO])
                        |> Table.RowCount()
                in
                    if TalhoesDiferentes > 1 then "SIM" else "NÃO"
            else if [ID_VIAGEM_N2] <> null then
                // Nível 2 encontrou: contar talhões no ID_VIAGEM_N2
                let
                    IdViagemN2 = [ID_VIAGEM_N2],
                    TalhoesDiferentes =
                        #"CDG com Data Chegada"
                        |> Table.SelectRows(each [ID_VIAGEM] = IdViagemN2)
                        |> Table.Group(each [CD_TALHAO])
                        |> Table.RowCount()
                in
                    if TalhoesDiferentes > 1 then "SIM" else "NÃO"
            else
                "NÃO",
        type text
    ),

    // ===================================================================
    // PASSO 2: CONSOLIDAR RESULTADO MATCH
    // ===================================================================

    #"Consolidar Resultado Match" = Table.AddColumn(
        #"Validar Multiplos Talhoes Viagem",
        "NIVEL_MATCH",
        each
            if [ID_VIAGEM_N1] <> null then "1_PLACA_EXATA"
            else if [ID_VIAGEM_N2] <> null then "2_TALHAO_NA_VIAGEM"
            else "0_SEM_MATCH",
        type text
    ),

    #"Consolidar ID_VIAGEM" = Table.AddColumn(
        #"Consolidar Resultado Match",
        "ID_VIAGEM_CONSOLIDADO",
        each
            if [NIVEL_MATCH] = "1_PLACA_EXATA" then [ID_VIAGEM_N1]
            else if [NIVEL_MATCH] = "2_TALHAO_NA_VIAGEM" then [ID_VIAGEM_N2]
            else null,
        type number
    ),

    // ===================================================================
    // PASSO 3: APLICAR JANELA DE ASSOCIAÇÃO (±3 DIAS)
    // ===================================================================

    #"Aplicar Janela" = Table.AddColumn(
        #"Consolidar ID_VIAGEM",
        "DENTRO_JANELA",
        each
            if [ID_VIAGEM_CONSOLIDADO] = null then false
            else if [NIVEL_MATCH] = "1_PLACA_EXATA" then
                if [DT_CHEGADA_CDG_N1] = null or [DATACHEGADA] = null then false
                else
                    let
                        DiffDias = Number.Abs(Duration.Days([DT_CHEGADA_CDG_N1] - [DATACHEGADA]))
                    in
                        DiffDias <= 3
            else if [NIVEL_MATCH] = "2_TALHAO_NA_VIAGEM" then
                if [DT_CHEGADA_CDG_N2] = null or [DATACHEGADA] = null then false
                else
                    let
                        DiffDias = Number.Abs(Duration.Days([DT_CHEGADA_CDG_N2] - [DATACHEGADA]))
                    in
                        DiffDias <= 3
            else
                false,
        type logical
    ),

    #"Filtrar Janela" = Table.SelectRows(
        #"Aplicar Janela",
        each [DENTRO_JANELA] = true or [ID_VIAGEM_CONSOLIDADO] = null
    ),

    // ===================================================================
    // PASSO 4: CALCULAR DIFERENÇAS DE TEMPO
    // ===================================================================

    #"Calcular DIFF DIAS" = Table.AddColumn(
        #"Filtrar Janela",
        "DIFF_DIAS_CHEGADA",
        each
            if [ID_VIAGEM_CONSOLIDADO] = null then null
            else
                let
                    DT_CDG = if [NIVEL_MATCH] = "1_PLACA_EXATA" then [DT_CHEGADA_CDG_N1]
                             else if [NIVEL_MATCH] = "2_TALHAO_NA_VIAGEM" then [DT_CHEGADA_CDG_N2]
                             else null
                in
                    if DT_CDG = null then null else Number.Abs(Duration.Days(DT_CDG - [DATACHEGADA])),
        type number
    ),

    #"Calcular DIFERENCA MINUTOS" = Table.AddColumn(
        #"Calcular DIFF DIAS",
        "DIFERENCA_HORA_MINUTOS",
        each
            if [ID_VIAGEM_CONSOLIDADO] = null then null
            else if [NIVEL_MATCH] = "1_PLACA_EXATA" then
                if [DT_HR_ENTRADA_CDG_N1] = null or [MINUTOS_CHEGADA_ROM] = null then null
                else
                    let
                        MinCDG = (Time.Hour(Time.From([DT_HR_ENTRADA_CDG_N1])) * 60) +
                                 Time.Minute(Time.From([DT_HR_ENTRADA_CDG_N1]))
                    in
                        Number.Abs([MINUTOS_CHEGADA_ROM] - MinCDG)
            else if [NIVEL_MATCH] = "2_TALHAO_NA_VIAGEM" then
                if [DT_HR_ENTRADA_CDG_N2] = null or [MINUTOS_CHEGADA_ROM] = null then null
                else
                    let
                        MinCDG = (Time.Hour(Time.From([DT_HR_ENTRADA_CDG_N2])) * 60) +
                                 Time.Minute(Time.From([DT_HR_ENTRADA_CDG_N2]))
                    in
                        Number.Abs([MINUTOS_CHEGADA_ROM] - MinCDG)
            else
                null,
        type number
    ),

    // ===================================================================
    // PASSO 5: CALCULAR SCORE
    // ===================================================================

    #"Calcular Score" = Table.AddColumn(
        #"Calcular DIFERENCA MINUTOS",
        "SCORE_CONFIANCA",
        each
            if [VALIDACAO_ROMANEIO] <> "OK" then 0
            else if [ID_VIAGEM_CONSOLIDADO] = null then 0
            else if [NIVEL_MATCH] = "1_PLACA_EXATA" then
                if [DIFERENCA_HORA_MINUTOS] = null then 0
                else if [DIFERENCA_HORA_MINUTOS] <= 5 then 100
                else if [DIFERENCA_HORA_MINUTOS] <= 15 then 90
                else if [DIFERENCA_HORA_MINUTOS] <= 30 then 80
                else if [DIFERENCA_HORA_MINUTOS] <= 60 then 60
                else if [DIFERENCA_HORA_MINUTOS] <= 120 then 40
                else 0
            else if [NIVEL_MATCH] = "2_TALHAO_NA_VIAGEM" then
                if [DIFERENCA_HORA_MINUTOS] = null then 0
                else if [DIFERENCA_HORA_MINUTOS] <= 5 then 75
                else if [DIFERENCA_HORA_MINUTOS] <= 10 then 70
                else 0
            else
                0,
        type number
    ),

    // ===================================================================
    // PASSO 6: VALIDAR DATA COLHEITA
    // ===================================================================

    #"Validar Data Colheita" = Table.AddColumn(
        #"Calcular Score",
        "DATA_COLHEITA_DIVERGENTE",
        each
            if [ID_VIAGEM_CONSOLIDADO] = null then ""
            else
                let
                    DT_COLHEITA_ROMANEIO = [DT_COLHEITA_ROM],
                    DT_COLHEITA_CDG_VAL =
                        if [NIVEL_MATCH] = "1_PLACA_EXATA" then [DT_COLHEITA_CDG_N1]
                        else if [NIVEL_MATCH] = "2_TALHAO_NA_VIAGEM" then [DT_COLHEITA_CDG_N2]
                        else null
                in
                    if DT_COLHEITA_ROMANEIO = null or DT_COLHEITA_CDG_VAL = null then "SEM_INFO"
                    else if DT_COLHEITA_ROMANEIO = DT_COLHEITA_CDG_VAL then ""
                    else "SIM",
        type text
    ),

    // ===================================================================
    // PASSO 7: DETERMINAR STATUS_MATCH
    // ===================================================================

    #"Adicionar Status Match" = Table.AddColumn(
        #"Validar Data Colheita",
        "STATUS_MATCH",
        each
            if [VALIDACAO_ROMANEIO] <> "OK" then "DADOS_INCOMPLETOS"
            else if [ID_VIAGEM_CONSOLIDADO] = null then "SEM_MATCH"
            else if [NIVEL_MATCH] = "1_PLACA_EXATA" then
                if [SCORE_CONFIANCA] = 0 then "SCORE_FRACO"
                else if [DATA_COLHEITA_DIVERGENTE] = "SIM" then "DIVERGENTE_DATA_COLHEITA"
                else "MATCH_ENCONTRADO"
            else if [NIVEL_MATCH] = "2_TALHAO_NA_VIAGEM" then
                if [SCORE_CONFIANCA] = 0 then "SCORE_FRACO"
                else if [DATA_COLHEITA_DIVERGENTE] = "SIM" then "DIVERGENTE_DATA_COLHEITA"
                else "MATCH_TALHAO_VIAGEM"
            else
                "SEM_MATCH",
        type text
    ),

    // ===================================================================
    // PASSO 8: DETERMINAR CONFIANÇA
    // ===================================================================

    #"Adicionar Confianca Match" = Table.AddColumn(
        #"Adicionar Status Match",
        "CONFIANCA_MATCH",
        each
            if [VALIDACAO_ROMANEIO] <> "OK" then "DADOS_INCOMPLETOS"
            else if [ID_VIAGEM_CONSOLIDADO] = null then "NENHUMA"
            else if [NIVEL_MATCH] = "1_PLACA_EXATA" then
                if [SCORE_CONFIANCA] >= 90 then "ALTA ✅"
                else if [SCORE_CONFIANCA] >= 60 then "MEDIA ⚠️"
                else if [SCORE_CONFIANCA] >= 40 then "BAIXA ⚠️"
                else "NENHUMA"
            else if [NIVEL_MATCH] = "2_TALHAO_NA_VIAGEM" then "MEDIA ⚠️"
            else
                "NENHUMA",
        type text
    ),

    // ===================================================================
    // PASSO 9: GERAR MOTIVO COM OBSERVAÇÃO DE MÚLTIPLOS TALHÕES
    // ===================================================================

    #"Adicionar Motivo" = Table.AddColumn(
        #"Adicionar Confianca Match",
        "MOTIVO_NAO_MATCH",
        each
            let
                Status = [STATUS_MATCH],
                Score = [SCORE_CONFIANCA],
                DiffMin = [DIFERENCA_HORA_MINUTOS],
                DiffDias = [DIFF_DIAS_CHEGADA],
                DataRom = [DATACHEGADA],
                DataCDG_N1 = [DT_CHEGADA_CDG_N1],
                DataCDG_N2 = [DT_CHEGADA_CDG_N2],
                DataCDG = if DataCDG_N1 <> null then DataCDG_N1 else DataCDG_N2,
                HoraRom = [HORACHEGADA],
                HoraCDG_N1 = [DT_HR_ENTRADA_CDG_N1],
                HoraCDG_N2 = [DT_HR_ENTRADA_CDG_N2],
                HoraCDG = if HoraCDG_N1 <> null then HoraCDG_N1 else HoraCDG_N2,
                IdViagem = [ID_VIAGEM_CONSOLIDADO],
                Confianca = [CONFIANCA_MATCH],
                Validacao = [VALIDACAO_ROMANEIO],
                ValidacaoCDG_N1 = [VALIDACAO_CDG_N1],
                ValidacaoCDG_N2 = [VALIDACAO_CDG_N2],
                ValidacaoCDG = if ValidacaoCDG_N1 <> null then ValidacaoCDG_N1 else ValidacaoCDG_N2,
                NivelMatch = [NIVEL_MATCH],
                PlacaRom = [USU_PLAVEI],
                PlacaCDG_N2 = [PLACA_CDG_N2],
                NumCAM_Rom = [NUMCAM],
                CD_TALHAO_CDG = if [NIVEL_MATCH] = "1_PLACA_EXATA" then [CD_TALHAO_N1]
                               else if [NIVEL_MATCH] = "2_TALHAO_NA_VIAGEM" then [CD_TALHAO_N2]
                               else null,
                MultiplosT = [MULTIPLOS_TALHOES_VIAGEM],
                // ⭐ NOVO: Observação se múltiplos talhões
                ObservacaoMultiplos = if MultiplosT = "SIM" then
                    " | ⚠️ AVISO: Esta viagem (ID=" & Text.From(IdViagem) & ") contém MÚLTIPLOS TALHÕES"
                else ""
            in
                if Validacao <> "OK"
                    then "❌ ROMANEIO INCOMPLETO | " & Validacao
                else if IdViagem = null
                    then "❌ SEM_MATCH | Placa não encontrada no CDG para " & Text.From(DataRom) & " | Possível erro de digitação de placa"
                else if ValidacaoCDG <> "OK"
                    then "❌ CDG INCOMPLETO | " & ValidacaoCDG
                else if NivelMatch = "1_PLACA_EXATA" then
                    if Status = "SCORE_FRACO"
                        then "❌ SCORE_FRACO (" & Confianca & ") | ROMANEIO: " & Text.From(DataRom) & " " & Text.From(HoraRom) & " | CDG: " & Text.From(DataCDG) & " " & Text.From(HoraCDG) & " | Desvio: " & Text.From(Int32.From(DiffMin)) & " min" & ObservacaoMultiplos
                    else if Status = "DIVERGENTE_DATA_COLHEITA"
                        then "⚠️ DIVERGENTE_DATA_COLHEITA (" & Confianca & ") | ROMANEIO: " & Text.From(DataRom) & " | CDG: " & Text.From(DataCDG) & " | Desvio chegada: " & Text.From(Int32.From(DiffMin)) & " min" & ObservacaoMultiplos
                    else "✅ MATCH_ENCONTRADO (" & Confianca & ") | ROMANEIO: " & Text.From(DataRom) & " " & Text.From(HoraRom) & " | CDG: " & Text.From(DataCDG) & " | Desvio: " & Text.From(Int32.From(DiffMin)) & " min" & ObservacaoMultiplos
                else if NivelMatch = "2_TALHAO_NA_VIAGEM" then
                    if Status = "SCORE_FRACO"
                        then "⚠️ SCORE_FRACO (" & Confianca & ") | ROMANEIO: Placa=" & PlacaRom & ", Talhão=" & Text.From(NumCAM_Rom) & " " & Text.From(DataRom) & " " & Text.From(HoraRom) & " | CDG: Talhão=" & CD_TALHAO_CDG & " " & Text.From(DataCDG) & " | Desvio: " & Text.From(Int32.From(DiffMin)) & " min" & ObservacaoMultiplos
                    else "✅ MATCH_TALHAO_VIAGEM (" & Confianca & ") | ROMANEIO: Placa=" & PlacaRom & ", Talhão=" & Text.From(NumCAM_Rom) & " " & Text.From(DataRom) & " | CDG: Talhão=" & CD_TALHAO_CDG & " | Desvio: " & Text.From(Int32.From(DiffMin)) & " min" & ObservacaoMultiplos
                else
                    "❌ SEM_MATCH | Nenhuma correspondência encontrada",
        type text
    ),

    // ===================================================================
    // PASSO 10: RENOMEAR E CONSOLIDAR
    // ===================================================================

    #"Renomear CODVIAGEM" = Table.RenameColumns(
        #"Adicionar Motivo",
        {{"CODVIAGEM", "CODVIAGEM_ORIGINAL"}}
    ),

    #"Adicionar CODVIAGEM_ENCONTRADO" = Table.AddColumn(
        #"Renomear CODVIAGEM",
        "CODVIAGEM_ENCONTRADO",
        each
            if [VALIDACAO_ROMANEIO] <> "OK" then null
            else if [ID_VIAGEM_CONSOLIDADO] = null then null
            else if [SCORE_CONFIANCA] = 0 then null
            else if [STATUS_MATCH] = "DIVERGENTE_DATA_COLHEITA" then null
            else [ID_VIAGEM_CONSOLIDADO],
        type number
    ),

    #"Adicionar Placa CDG Sugerida" = Table.AddColumn(
        #"Adicionar CODVIAGEM_ENCONTRADO",
        "PLACA_CDG_SUGERIDA",
        each
            if [NIVEL_MATCH] = "2_TALHAO_NA_VIAGEM" then [PLACA_CDG_N2]
            else null,
        type text
    ),

    #"Adicionar ID_CAMINHAO_CDG" = Table.AddColumn(
        #"Adicionar Placa CDG Sugerida",
        "ID_CAMINHAO_CDG",
        each
            if [NIVEL_MATCH] = "1_PLACA_EXATA" then [ID_CAMINHAO_N1]
            else if [NIVEL_MATCH] = "2_TALHAO_NA_VIAGEM" then [ID_CAMINHAO_N2]
            else null,
        type text
    ),

    #"Preparar Saida Final" = Table.AddColumn(
        #"Adicionar ID_CAMINHAO_CDG",
        "ID_VIAGEM",
        each [ID_VIAGEM_CONSOLIDADO],
        type number
    ),

    #"Preparar Saida QTD_LINHAS" = Table.AddColumn(
        #"Preparar Saida Final",
        "QTD_LINHAS_ID_VIAGEM",
        each
            if [NIVEL_MATCH] = "1_PLACA_EXATA" then [QTD_LINHAS_N1]
            else if [NIVEL_MATCH] = "2_TALHAO_NA_VIAGEM" then [QTD_LINHAS_N2]
            else null,
        type number
    ),

    #"Preparar Saida COMPLETUDE_CDG" = Table.AddColumn(
        #"Preparar Saida QTD_LINHAS",
        "COMPLETUDE_CDG_EXP",
        each
            if [NIVEL_MATCH] = "1_PLACA_EXATA" then [COMPLETUDE_CDG_N1]
            else if [NIVEL_MATCH] = "2_TALHAO_NA_VIAGEM" then [COMPLETUDE_CDG_N2]
            else "INCOMPLETO ⚠️",
        type text
    ),

    // ===================================================================
    // PASSO 11: REMOVER COLUNAS AUXILIARES
    // ===================================================================

    #"Remover Auxiliares" = Table.RemoveColumns(
        #"Preparar Saida COMPLETUDE_CDG",
        {
            "PLACA_UPPER", "NIVEL_MATCH", "VALIDACAO_ROMANEIO",
            "ID_VIAGEM_N1", "ID_VIAGEM_N2", "ID_VIAGEM_CONSOLIDADO",
            "DT_COLHEITA_CDG_N1", "DT_HR_CAMPO_CDG_N1", "DT_HR_ENTRADA_CDG_N1",
            "DT_CHEGADA_CDG_N1", "CD_TALHAO_N1", "ID_CAMINHAO_N1",
            "QTD_LINHAS_N1", "VALIDACAO_CDG_N1", "COMPLETUDE_CDG_N1",
            "DT_COLHEITA_CDG_N2", "DT_HR_CAMPO_CDG_N2", "DT_HR_ENTRADA_CDG_N2",
            "DT_CHEGADA_CDG_N2", "CD_TALHAO_N2", "ID_CAMINHAO_N2",
            "PLACA_CDG_N2", "QTD_LINHAS_N2", "VALIDACAO_CDG_N2", "COMPLETUDE_CDG_N2",
            "DENTRO_JANELA", "DATA_COLHEITA_DIVERGENTE", "MINUTOS_CHEGADA_ROM"
        }
    ),

    // ===================================================================
    // PASSO 12: REORDENAR COLUNAS
    // ===================================================================

    #"Reordenar Colunas" = Table.ReorderColumns(
        #"Remover Auxiliares",
        {
            "CODAGR", "CODVIAGEM_ORIGINAL", "CODVIAGEM_ENCONTRADO",
            "COMPLETUDE_ROMANEIO", "COMPLETUDE_CDG_EXP", "STATUS_MATCH", "CONFIANCA_MATCH",
            "MOTIVO_NAO_MATCH", "MULTIPLOS_TALHOES_VIAGEM",  // ⭐ NOVA COLUNA VISÍVEL
            "SCORE_CONFIANCA", "DIFERENCA_HORA_MINUTOS", "DIFF_DIAS_CHEGADA",
            "USU_PLAVEI", "DATACHEGADA", "HORACHEGADA", "DT_CHEGADA_CDG", "DT_HR_ENTRADA_CDG",
            "USU_DATCOL", "DT_COLHEITA_ROM", "DT_COLHEITA_CDG", "NUM_CTRL",
            "ID_VIAGEM", "QTD_LINHAS_ID_VIAGEM",
            "PLACA_CDG_SUGERIDA", "ID_CAMINHAO_CDG"
        } & List.Difference(Table.ColumnNames(#"Remover Auxiliares"), {
            "CODAGR", "CODVIAGEM_ORIGINAL", "CODVIAGEM_ENCONTRADO",
            "COMPLETUDE_ROMANEIO", "COMPLETUDE_CDG_EXP", "STATUS_MATCH", "CONFIANCA_MATCH",
            "MOTIVO_NAO_MATCH", "MULTIPLOS_TALHOES_VIAGEM",
            "SCORE_CONFIANCA", "DIFERENCA_HORA_MINUTOS", "DIFF_DIAS_CHEGADA",
            "USU_PLAVEI", "DATACHEGADA", "HORACHEGADA", "DT_CHEGADA_CDG", "DT_HR_ENTRADA_CDG",
            "USU_DATCOL", "DT_COLHEITA_ROM", "DT_COLHEITA_CDG", "NUM_CTRL",
            "ID_VIAGEM", "QTD_LINHAS_ID_VIAGEM",
            "PLACA_CDG_SUGERIDA", "ID_CAMINHAO_CDG"
        })
    )
in
    #"Reordenar Colunas"

// ===================================================================
// RESULTADO FINAL: MATCHING COM MÚLTIPLOS TALHÕES DETECTADOS
// ✅ Nível 1: Match exato por placa
// ✅ Nível 2: Match por talhão dentro da viagem (NOVO!)
// ✅ Aviso: Detecta múltiplos talhões e adiciona observação
// ✅ MULTIPLOS_TALHOES_VIAGEM: Coluna visível para auditoria
// ===================================================================
