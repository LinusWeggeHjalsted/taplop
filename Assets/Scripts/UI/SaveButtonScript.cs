using UnityEngine;
using UnityEngine.UI;

public class SaveButtonScript : MonoBehaviour
{
    public Button button;

    public void OnActivate()
    {
        SoundControllerScript.Instance.PlayButtonClickSound();
        GameObject player = GameReferences.GetPlayer();
        PlayerDataScript.Instance.BuildDataFromPlayer(player);
        string savePath = PlayerDataScript.Instance.playerName;
        PlayerDataScript.Instance.SavePlayerData(savePath);
    }

    void Start()
    {
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
    }
}
