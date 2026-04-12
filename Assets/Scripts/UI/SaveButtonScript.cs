using UnityEngine;
using UnityEngine.UI;
using UnityEngine.EventSystems;

public class SaveButtonScript : MonoBehaviour, IPointerDownHandler
{
    public Button button;

    public void OnPointerDown(PointerEventData eventData)
    {
        SoundControllerScript.Instance.PlayButtonClickDownSound();
    }

    public void OnActivate()
    {
        SoundControllerScript.Instance.PlayButtonClickUpSound();
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
