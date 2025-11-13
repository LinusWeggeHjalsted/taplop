using UnityEngine;

public class GameControllerScript : MonoBehaviour
{
    public GameObject mainMenuPrefab;
    public GameObject missionPrefab;
    public GameObject missionLogic;
    public GameObject hubPrefab;
    public GameObject hub;

    public void MainMenu()
    {
        // to-do
    }

    public void StartMission(string missionName, int missionLength, string endHub)
    {
        // to-do - start loading screen
        if (hub != null)
        {
            Destroy(hub);
        }
        missionLogic = Instantiate(missionPrefab);
        missionLogic.name = "Mission Logic";
        MissionLogicScript missionLogicScript = missionLogic.GetComponent<MissionLogicScript>();
        missionLogicScript.missionName = missionName;
        missionLogicScript.missionLength = missionLength;
        missionLogicScript.endHub = endHub;
    }

    public void EnterHub(string hubName)
    {
        // to-do - start loading screen
        // to-do - add hub to discovered locations in PlayerData
        if (missionLogic != null)
        {
            Destroy(missionLogic);
        }
        hub = Instantiate(hubPrefab);
        HubScript hubScript = hub.GetComponent<HubScript>();
        hubScript.hubName = hubName;
    }

    void Start()
    {
        mainMenuPrefab = Resources.Load<GameObject>("Prefabs/Main Menu");
        missionPrefab = Resources.Load<GameObject>("Prefabs/Mission Logic");
        hubPrefab = Resources.Load<GameObject>("Prefabs/Hub");
        StartMission("Beginnings", 3, "TestHub");
    }
}
