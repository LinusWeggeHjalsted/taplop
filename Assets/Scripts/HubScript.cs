using UnityEngine;

public class HubScript : MonoBehaviour
{
    public static HubScript Instance { get; private set; }

    // Core hub objects
    public GameObject player;
    public GameObject hubBuilder;
    public GameObject hubTiles;
    public GameObject hubExits;

    // UI objects (shared with levels)
    public GameObject canvas;
    public GameObject characterUI;
    public GameObject playerHealthBar;

    // Scripts (cached references)
    public HubPlayerScript hubPlayerScript;
    public HubBuilderScript hubBuilderScript;
    public HubTilesScript hubTilesScript;
    public HubExitsScript hubExitsScript;

    void Awake()
    {
        if (Instance != null && Instance != this)
        {
            Destroy(this.gameObject);
            return;
        }
        Instance = this;

        // Cache all references
        CacheReferences();
    }

    void OnDestroy()
    {
        if (Instance == this)
        {
            Instance = null;
        }
    }

    private void CacheReferences()
    {
        // Find core hub objects
        player = GameObject.Find("Player");
        hubBuilder = GameObject.Find("Hub Builder");
        hubTiles = GameObject.Find("Hub Tiles");
        hubExits = GameObject.Find("Hub Exits");

        // Find UI objects
        canvas = GameObject.Find("Canvas");
        characterUI = GameObject.Find("Character UI");
        playerHealthBar = GameObject.Find("Player Health Bar");

        // Cache script references
        if (player != null)
        {
            hubPlayerScript = player.GetComponent<HubPlayerScript>();
        }
        if (hubBuilder != null)
        {
            hubBuilderScript = hubBuilder.GetComponent<HubBuilderScript>();
        }
        if (hubTiles != null)
        {
            hubTilesScript = hubTiles.GetComponent<HubTilesScript>();
        }
        if (hubExits != null)
        {
            hubExitsScript = hubExits.GetComponent<HubExitsScript>();
        }
    }
}
