using UnityEngine;
using UnityEngine.UI;

public class RestartMissionButtonScript : MonoBehaviour
{
    public Button button;

    public void OnActivate()
    {
        SoundControllerScript.Instance.PlayButtonClickSound(new Vector3(Screen.width / 2f, Screen.height / 2f, 0));
        GameObject player = GameObject.Find("Player");
        if (player != null)
        {
            PlayerDataScript.Instance.BuildDataFromPlayer(player);
        }
#if !UNITY_WEBGL || UNITY_EDITOR
        PlayerDataScript.Instance.SavePlayerData("Autosave");
#endif
        string missionName = MissionLogicScript.Instance.missionName;
        int missionLength = MissionLogicScript.Instance.missionLength;
        string endHub = MissionLogicScript.Instance.endHub;
        GameControllerScript.Instance.StartMission(missionName, missionLength, endHub);
    }

    void Start()
    {
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);

        GameObject missionLogic = GameObject.Find("Mission Logic");
        if (missionLogic == null)
        {
            this.gameObject.SetActive(false);
        }
    }
}
