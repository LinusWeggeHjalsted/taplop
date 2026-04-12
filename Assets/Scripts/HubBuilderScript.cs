using UnityEngine;
using System;
using System.Collections;
using System.Collections.Generic;
using System.Linq;

public class HubBuilderScript : MonoBehaviour
{
    public class PreParse
    {
        public string[] hubMetadata;
        public char[][] hubLayout;
        public List<string[]> decorationInfo;
        public List<string[]> exitInfo;
    }

    public class PreDecoration
    {
        public string decorationSprite;
        public int colorCode;
    }

    public class PreExit
    {
        public string missionName;
        public int missionLength;
        public string endHub;
    }

    public class ParsedHub
    {
        public List<Vector3> tilePositions;
        public Vector3 playerPosition;
        public Dictionary<Vector3, char> decorationPositions;
        public Dictionary<char, PreDecoration> preDecorations;
        public Dictionary<Vector3, char> exitPositions;
        public Dictionary<char, PreExit> preExits;
    }

    public bool finishedBuilding = false;
    public string hubName;
    public GameObject player;
    public GameObject hubTiles;
    public GameObject decorations;
    public GameObject hubExits;
    public GameObject tilePrefab;
    public GameObject decorationPrefab;
    public GameObject exitPrefab;

    public PreParse LoadHubFile(string hubPath)
    {
        PreParse preParse = new PreParse();
        TextAsset hubFile = Resources.Load<TextAsset>(hubPath);
        if (hubFile == null)
        {
            Debug.LogError("No hub file found at path " + hubPath);
        }
        else
        {
            string[] fileLines = hubFile.text.Split('\n');
            string[] sectionHeaders = new string[] {
                "Metadata",
                "Layout",
                "Decoration Info",
                "Exit Info"
            };
            int sectionCount = sectionHeaders.Length;
            int[] sectionIndices = new int[sectionCount];
            for (int i = 0; i < sectionCount; i++)
            {
                int sectionIndex = Array.IndexOf(fileLines, sectionHeaders[i]) + 1;
                sectionIndices[i] = sectionIndex;
            }
            // to-do: verify that sections are in correct order
            int[] sectionLengths = new int[sectionCount];
            for (int i = 0; i < sectionCount; i++)
            {
                if (i + 1 == sectionCount)
                {
                    int sectionLength = fileLines.Length - sectionIndices[i] - 2;
                    sectionLengths[i] = sectionLength;
                }
                else
                {
                    int sectionLength = sectionIndices[i + 1] - sectionIndices[i] - 2;
                    sectionLengths[i] = sectionLength;
                }
            }
            string[][] sectionBlocks = new string[sectionCount][];
            for (int i = 0; i < sectionCount; i++)
            {
                string[] sectionBlock = new string[sectionLengths[i]];
                Array.Copy(fileLines, sectionIndices[i], sectionBlock, 0, sectionLengths[i]);
                sectionBlocks[i] = sectionBlock;
            }

            // metadata
            string[] metadataBlock = sectionBlocks[0];

            // layout
            int layoutLength = sectionLengths[1];
            string[] layoutBlock = sectionBlocks[1];
            char[][] layout = new char[layoutLength][];
            for (int i = 0; i < layoutLength; i++)
            {
                layout[i] = layoutBlock[i].ToCharArray();
            }

            // decoration info
            string[] decorationInfoBlock = sectionBlocks[2];
            List<string[]> decorationInfo = new List<string[]>();
            List<string> currentSubArray = new List<string>();
            foreach (string line in decorationInfoBlock)
            {
                if (line == "")
                {
                    decorationInfo.Add(currentSubArray.ToArray());
                    currentSubArray.Clear();
                }
                else
                {
                    currentSubArray.Add(line);
                }
            }
            if (currentSubArray.Count > 0)
            {
                decorationInfo.Add(currentSubArray.ToArray());
            }

            // exit info
            string[] exitInfoBlock = sectionBlocks[3];
            List<string[]> exitInfo = new List<string[]>();
            currentSubArray = new List<string>();
            foreach (string line in exitInfoBlock)
            {
                if (line == "")
                {
                    exitInfo.Add(currentSubArray.ToArray());
                    currentSubArray.Clear();
                }
                else
                {
                    currentSubArray.Add(line);
                }
            }
            if (currentSubArray.Count > 0)
            {
                exitInfo.Add(currentSubArray.ToArray());
            }

            preParse.hubMetadata = metadataBlock;
            preParse.hubLayout = layout;
            preParse.decorationInfo = decorationInfo;
            preParse.exitInfo = exitInfo;
        }
        return preParse;
    }

    public ParsedHub ParseHub(PreParse preParse)
    {
        ParsedHub parsedHub = new ParsedHub();
        parsedHub.tilePositions = new List<Vector3>();
        parsedHub.decorationPositions = new Dictionary<Vector3, char>();
        parsedHub.preDecorations = new Dictionary<char, PreDecoration>();
        parsedHub.exitPositions = new Dictionary<Vector3, char>();
        parsedHub.preExits = new Dictionary<char, PreExit>();
        // parse individual decoration information
        foreach (string[] decorationStrings in preParse.decorationInfo)
        {
            PreDecoration preDecoration = new PreDecoration();
            if (decorationStrings[0].Length > 1)
            {
                Debug.LogError("bad decoration info, first line should be a single character");
                continue;
            }
            char decorationCode = decorationStrings[0][0];
            for (int i = 1; i < decorationStrings.Length; i++)
            {
                string currentLine = decorationStrings[i];
                if (currentLine.StartsWith("sprite "))
                {
                    string decorationSprite = currentLine.Substring("sprite ".Length);
                    preDecoration.decorationSprite = decorationSprite;
                }
                else if (currentLine.StartsWith("colorCode "))
                {
                    string colorCode = currentLine.Substring("colorCode ".Length);
                    int colorCodeNumber;
                    if (Int32.TryParse(colorCode, out colorCodeNumber))
                    {
                        preDecoration.colorCode = colorCodeNumber;
                    }
                    else
                    {
                        Debug.LogError("colorCode is not a number");
                    }
                }
            }
            parsedHub.preDecorations.Add(decorationCode, preDecoration);
        }
        // parse individual exit information
        foreach (string[] exitStrings in preParse.exitInfo)
        {
            PreExit preExit = new PreExit();
            if (exitStrings[0].Length > 1)
            {
                Debug.LogError("bad exit info, first line should be a single character");
                continue;
            }
            char exitCode = exitStrings[0][0];
            for (int i = 1; i < exitStrings.Length; i++)
            {
                string currentLine = exitStrings[i];
                if (currentLine.StartsWith("missionName "))
                {
                    string missionName = currentLine.Substring("missionName ".Length);
                    preExit.missionName = missionName;
                }
                else if (currentLine.StartsWith("missionLength "))
                {
                    string missionLength = currentLine.Substring("missionLength ".Length);
                    int missionLengthNumber;
                    if (Int32.TryParse(missionLength, out missionLengthNumber))
                    {
                        preExit.missionLength = missionLengthNumber;
                    }
                    else
                    {
                        Debug.LogError("missionLength is not a number");
                    }
                }
                else if (currentLine.StartsWith("endHub "))
                {
                    string endHub = currentLine.Substring("endHub ".Length);
                    preExit.endHub = endHub;
                }
            }
            parsedHub.preExits.Add(exitCode, preExit);
        }
        // find positions of things
        for (int i = 0; i < preParse.hubLayout.Length; i++)
        {
            for (int j = 0; j < preParse.hubLayout[i].Length; j++)
            {
                // flip y axis
                Vector3 position = new Vector3(j, preParse.hubLayout.Length - i, 0);
                char tileCode = preParse.hubLayout[i][j];
                if (tileCode != ' ')
                {
                    parsedHub.tilePositions.Add(position);
                    if (tileCode == '.')
                    {
                        continue;
                    }
                    if (tileCode == '!')
                    {
                        parsedHub.playerPosition = position;
                        continue;
                    }
                    else
                    {
                        if (parsedHub.preDecorations.ContainsKey(tileCode))
                        {
                            parsedHub.decorationPositions.Add(position, tileCode);
                            parsedHub.tilePositions.Remove(position);
                        }
                        if (parsedHub.preExits.ContainsKey(tileCode))
                        {
                            parsedHub.exitPositions.Add(position, tileCode);
                        }
                    }
                }
            }
        }
        return parsedHub;
    }

    public void BuildHub(ParsedHub parsedHub)
    {
        player.transform.position = parsedHub.playerPosition;
        HubPlayerScript playerScript = player.GetComponent<HubPlayerScript>();
        playerScript.spriteRenderer.sortingOrder = 10 * (int)-parsedHub.playerPosition.y;
        playerScript.mainHandWeaponSpriteRenderer.sortingOrder = 10 * (int)-parsedHub.playerPosition.y + 1;
        playerScript.offHandWeaponSpriteRenderer.sortingOrder = 10 * (int)-parsedHub.playerPosition.y + 1;
        CameraControllerScript.Instance.MoveToPlayer();
        // build tiles
        for (int i = 0; i < parsedHub.tilePositions.Count; i++)
        {
            GameObject newTile = Instantiate(tilePrefab, hubTiles.transform);
            newTile.transform.position = parsedHub.tilePositions[i];
            SpriteRenderer tileRenderer = newTile.GetComponent<SpriteRenderer>();
            switch ((newTile.transform.position.x + newTile.transform.position.y) % 2)
            {
                case 0:
                    tileRenderer.color = HubScript.Instance.hubColors[1];
                    break;
                case 1:
                    tileRenderer.color = HubScript.Instance.hubColors[3];
                    break;
            }
        }
        // build decorations
        foreach (Vector3 decorationPosition in parsedHub.decorationPositions.Keys)
        {
            char decorationCode = parsedHub.decorationPositions[decorationPosition];
            if (!parsedHub.preDecorations.ContainsKey(decorationCode))
            {
                Debug.LogError($"no decoration info for decoration code {decorationCode}");
                continue;
            }
            PreDecoration preDecoration = parsedHub.preDecorations[decorationCode];
            GameObject newDecoration = Instantiate(decorationPrefab, decorations.transform);
            newDecoration.transform.position = decorationPosition;
            SpriteRenderer decorationRenderer = newDecoration.GetComponent<SpriteRenderer>();
            decorationRenderer.sortingOrder = 10 * (int)-decorationPosition.y;
            decorationRenderer.color = HubScript.Instance.hubColors[preDecoration.colorCode];
            DecorationScript newDecorationScript = newDecoration.GetComponent<DecorationScript>();
            if (preDecoration.decorationSprite != null)
            {
                Sprite[] decorationSpriteSheet = Resources.LoadAll<Sprite>("Decorations/" + preDecoration.decorationSprite);
                if (decorationSpriteSheet == null)
                {
                    Debug.LogError($"no decoration sprite found called {preDecoration.decorationSprite}");
                }
                else
                {
                    newDecorationScript.SpriteSheet = decorationSpriteSheet;
                }
            }
        }
        // build exits
        foreach (Vector3 exitPosition in parsedHub.exitPositions.Keys)
        {
            char exitCode = parsedHub.exitPositions[exitPosition];
            if (!parsedHub.preExits.ContainsKey(exitCode))
            {
                Debug.LogError("no exit info for exit code " + exitCode.ToString());
                continue;
            }
            PreExit preExit = parsedHub.preExits[exitCode];
            GameObject newExit = Instantiate(exitPrefab, hubExits.transform);
            newExit.transform.position = exitPosition;
            SpriteRenderer exitRenderer = newExit.GetComponent<SpriteRenderer>();
            exitRenderer.sortingOrder = 10 * (int)-exitPosition.y;
            ExitScript exitScript = newExit.GetComponent<ExitScript>();
            exitScript.missionName = preExit.missionName;
            exitScript.missionLength = preExit.missionLength;
            exitScript.endHub = preExit.endHub;
        }
    }

    IEnumerator WaitForGameController()
    {
        while (hubName == null)
        {
            yield return null;
        }
        BuildHub(ParseHub(LoadHubFile("Hubs/" + hubName)));
        yield return StartCoroutine(PlayerDataScript.Instance.BuildPlayerFromData(player));
        HubPlayerScript hubPlayerScript = player.GetComponent<HubPlayerScript>();
        hubPlayerScript.CurrentHealth = hubPlayerScript.MaxHealth;
        finishedBuilding = true;
    }

    void Awake()
    {
        tilePrefab = Resources.Load<GameObject>("Prefabs/Tile");
        decorationPrefab = Resources.Load<GameObject>("Prefabs/Decoration");
        exitPrefab = Resources.Load<GameObject>("Prefabs/Exit");
    }

    void Start()
    {
        if (HubScript.Instance != null)
        {
            player = HubScript.Instance.player;
            hubTiles = HubScript.Instance.hubTiles;
            decorations = HubScript.Instance.decorations;
            hubExits = HubScript.Instance.hubExits;
            HubScript.Instance.mainCamera.GetComponent<Camera>().backgroundColor = HubScript.Instance.hubColors[2];
        }
        StartCoroutine(WaitForGameController());
    }
}
